import AVFoundation
import Combine
import CoreMedia
import KuhtakeDeckLink

/// A Blackmagic DeckLink / UltraStudio input as seen by the app.
struct DeckLinkDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Keeps the list of connected DeckLink devices current (arrivals and removals are pushed by the driver).
final class DeckLinkDirectory: ObservableObject {
    static let shared = DeckLinkDirectory()

    @Published private(set) var devices: [DeckLinkDevice] = []
    @Published private(set) var driverAvailable = false
    @Published private(set) var driverVersion: String?

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .KTDeckLinkDevicesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        // Devices that are already plugged in are reported shortly after discovery starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func refresh() {
        driverAvailable = KTDeckLinkDiscovery.isDriverAvailable()
        if driverAvailable, driverVersion == nil { driverVersion = KTDeckLinkDiscovery.driverVersion() }
        devices = KTDeckLinkDiscovery.devices().map { DeckLinkDevice(id: $0.identifier, name: $0.displayName) }
    }

    func name(for id: String?) -> String? {
        devices.first { $0.id == id }?.name
    }
}

/// Native DeckLink capture of one device into the frame hub. The wrapper (`KTDeckLinkCapture`) supervises the
/// input once a second: it reopens the device after a disconnect, follows format changes and restarts a stream
/// that stalls. On top of that, `AppController` checks the frame flow and recreates the whole capture if the
/// wrapper itself should ever get stuck (see `forceRestart`).
final class DeckLinkEngine {
    enum State: Equatable {
        case waitingForDevice, starting, noSignal, running, inUse, failed

        init(_ s: KTDeckLinkCaptureState) {
            switch s {
            case .waitingForDevice: self = .waitingForDevice
            case .starting: self = .starting
            case .noSignal: self = .noSignal
            case .running: self = .running
            case .inUse: self = .inUse
            case .failed: self = .failed
            @unknown default: self = .failed
            }
        }
    }

    private let hub: FrameHub
    /// Opening and closing run here, one after the other (stopping waits for the driver).
    private let control = DispatchQueue(label: "kuhtake.decklink.control", qos: .userInitiated)
    private var capture: KTDeckLinkCapture?
    private var hardRestarts = 0

    /// Main queue.
    var onStateChange: ((State) -> Void)?
    private(set) var deviceID: String?
    private(set) var state: State = .waitingForDevice

    var isActive: Bool { capture != nil }
    var activeDeviceName: String? { capture?.activeDeviceName }
    var signalFormat: String? { capture?.activeFormatName }
    /// Reconnects done by the input supervision plus forced restarts.
    var restartCount: Int { (capture?.restartCount ?? 0) + hardRestarts }

    init(hub: FrameHub) {
        self.hub = hub
    }

    func start(deviceID: String?) {
        if capture != nil, self.deviceID == deviceID { return }
        stop()
        self.deviceID = deviceID
        hardRestarts = 0
        open()
    }

    func stop() {
        guard let old = capture else { return }
        capture = nil
        deviceID = nil
        old.stateHandler = nil
        old.videoHandler = nil
        old.audioHandler = nil
        control.async { old.stop() }
        hub.reset()
        setState(.waitingForDevice)
    }

    /// Throws the capture away and starts a fresh one (watchdog of last resort).
    func forceRestart() {
        guard let old = capture else { return }
        let id = deviceID
        old.stateHandler = nil
        old.videoHandler = nil
        old.audioHandler = nil
        capture = nil
        control.async { old.stop() }
        hub.reset()
        hardRestarts += 1
        deviceID = id
        open()
    }

    private func open() {
        let c = KTDeckLinkCapture(deviceIdentifier: deviceID)
        c.videoHandler = { [hub] pb, time in
            hub.pushVideo(pb, pts: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
        }
        let packer = PCMPacker()
        c.audioHandler = { [hub] samples, frames, channels, time in
            guard let sb = packer.sampleBuffer(samples, frames: frames, channels: channels, time: time) else { return }
            hub.pushAudio(sb)
        }
        c.stateHandler = { [weak self, weak c] s in
            DispatchQueue.main.async {
                guard let self, let c, self.capture === c else { return }
                self.setState(State(s))
            }
        }
        capture = c
        setState(.starting)
        // After any stop queued before, so the input is free again.
        control.async { c.start() }
    }

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }

}

/// Interleaved 32-bit PCM from the card → CMSampleBuffer for the recorder and meters.
/// One per capture; only used on that capture's thread.
private final class PCMPacker {
    private var audioFormat: CMAudioFormatDescription?

    func sampleBuffer(_ samples: UnsafePointer<Int32>, frames: Int, channels: Int, time: Double) -> CMSampleBuffer? {
        if audioFormat == nil || CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat!)?.pointee.mChannelsPerFrame != UInt32(channels) {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
            audioFormat = fmt
        }
        guard let audioFormat else { return nil }

        let length = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }

        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}
