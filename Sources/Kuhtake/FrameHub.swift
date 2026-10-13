import AVFoundation
import Combine
import CoreMedia

/// Receives video/audio samples while a recording is running.
protocol CaptureSink: AnyObject {
    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
}

/// The one place every input (screen capture or DeckLink) delivers to. Keeps the latest picture for
/// the detector and previews, forwards everything to the recorder and to live preview views.
final class FrameHub {
    typealias VideoObserver = (CVPixelBuffer, CMTime) -> Void

    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    private weak var _sink: CaptureSink?
    private var observers: [UUID: VideoObserver] = [:]
    private var _lastFrameAt: TimeInterval = 0
    private var _frameCount = 0

    let meter = AudioMeter()

    var latestPixelBuffer: CVPixelBuffer? { lock.withLock { _latest } }

    var sink: CaptureSink? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    /// Seconds since the last picture arrived (∞ if none yet).
    var lastFrameAge: TimeInterval {
        let t = lock.withLock { _lastFrameAt }
        return t == 0 ? .infinity : ProcessInfo.processInfo.systemUptime - t
    }

    /// Pictures received since the last call.
    func takeFrameCount() -> Int {
        lock.withLock { defer { _frameCount = 0 }; return _frameCount }
    }

    // MARK: Producers (capture threads)

    func pushVideo(_ pb: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        _latest = pb
        _lastFrameAt = ProcessInfo.processInfo.systemUptime
        _frameCount += 1
        let sink = _sink
        let observers = Array(observers.values)
        lock.unlock()
        sink?.appendVideo(pb, pts: pts)
        for o in observers { o(pb, pts) }
    }

    func pushAudio(_ sb: CMSampleBuffer) {
        sink?.appendAudio(sb)
        meter.process(sb)
    }

    /// Source switched or lost: nothing current to show any more.
    func reset() {
        lock.withLock {
            _latest = nil
            _lastFrameAt = 0
            _frameCount = 0
        }
        meter.reset()
    }

    // MARK: Observers

    func addVideoObserver(_ observer: @escaping VideoObserver) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    func removeVideoObserver(_ id: UUID) {
        lock.withLock { _ = observers.removeValue(forKey: id) }
    }
}

/// Peak level per channel of the incoming sound, for the meters in the preview.
final class AudioMeter: ObservableObject {
    /// dBFS per channel, −60…0.
    @Published private(set) var levels: [Float] = []

    private let lock = NSLock()
    private var peaks: [Float] = []
    private var lastPublish: TimeInterval = 0
    static let floor: Float = -60

    func reset() {
        lock.withLock { peaks = [] }
        DispatchQueue.main.async { self.levels = [] }
    }

    func process(_ sb: CMSampleBuffer) {
        guard let fmt = sb.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return }

        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        var channelPeaks: [Float] = []
        for buffer in UnsafeMutableAudioBufferListPointer(ablPtr) {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            var p = [Float](repeating: 0, count: channels)
            let bytesPerSample = max(1, bits / 8)
            let count = Int(buffer.mDataByteSize) / bytesPerSample
            switch (isFloat, bits) {
            case (true, 32):
                let s = data.assumingMemoryBound(to: Float.self)
                for i in 0..<count { p[i % channels] = max(p[i % channels], abs(s[i])) }
            case (false, 32):
                let s = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<count { p[i % channels] = max(p[i % channels], abs(Float(s[i]) / 2_147_483_648)) }
            case (false, 16):
                let s = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<count { p[i % channels] = max(p[i % channels], abs(Float(s[i]) / 32_768)) }
            default:
                continue
            }
            channelPeaks.append(contentsOf: p)
        }
        guard !channelPeaks.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if peaks.count != channelPeaks.count { peaks = channelPeaks } else {
            for i in peaks.indices { peaks[i] = max(peaks[i], channelPeaks[i]) }
        }
        var publish: [Float]?
        if now - lastPublish >= 1.0 / 20 {
            lastPublish = now
            publish = peaks.map { $0 > 0 ? max(Self.floor, 20 * log10($0)) : Self.floor }
            peaks = peaks.map { _ in 0 }
        }
        lock.unlock()
        if let publish {
            DispatchQueue.main.async { self.levels = publish }
        }
    }
}
