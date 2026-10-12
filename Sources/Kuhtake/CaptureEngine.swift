import AppKit
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case sourceNotFound(String)
    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let s): return "Quelle „\(s)“ ist derzeit nicht verfügbar."
        }
    }
}

/// Receives video/audio samples while a recording is running.
protocol CaptureSink: AnyObject {
    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
}

/// Keeps a ScreenCaptureKit stream of the selected window/display running in the background.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "kuhtake.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "kuhtake.capture.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    private weak var _sink: CaptureSink?

    /// Called on the main queue when the stream stops unexpectedly (window closed, etc.).
    var onUnexpectedStop: ((Error) -> Void)?

    var isRunning: Bool { stream != nil }

    var latestPixelBuffer: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    var sink: CaptureSink? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    // MARK: Start / stop

    @MainActor
    func start(source: CaptureSource, frameRate: FrameRateOption, captureAudio: Bool, showCursor: Bool) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try Self.makeFilter(for: source, content: content)

        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        cfg.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        cfg.minimumFrameInterval = frameRate.frameDuration
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 6
        cfg.showsCursor = showCursor
        cfg.captureResolution = .best
        cfg.ignoreShadowsSingleWindow = true
        cfg.capturesAudio = captureAudio
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await s.startCapture()
        stream = s
    }

    @MainActor
    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        lock.withLock { _latest = nil }
    }

    static func makeFilter(for source: CaptureSource, content: SCShareableContent) throws -> SCContentFilter {
        switch source.kind {
        case .window:
            let windows = content.windows
            let match = windows.first { $0.windowID == source.windowID }
                ?? windows.first {
                    $0.owningApplication?.bundleIdentifier == source.appBundleID && $0.title == source.windowTitle
                }
                ?? windows
                    .filter { $0.owningApplication?.bundleIdentifier == source.appBundleID && $0.windowLayer == 0 && $0.isOnScreen }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let window = match else {
                throw CaptureError.sourceNotFound(source.label)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == source.displayID }) ?? content.displays.first else {
                throw CaptureError.sourceNotFound(source.label)
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                let rawStatus = attachments.first?[.status] as? Int,
                SCFrameStatus(rawValue: rawStatus) == .complete,
                let pb = sampleBuffer.imageBuffer
            else { return }
            lock.lock()
            _latest = pb
            let sink = _sink
            lock.unlock()
            sink?.appendVideo(pb, pts: sampleBuffer.presentationTimeStamp)
        case .audio:
            sink?.appendAudio(sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.lock.lock(); self._latest = nil; self.lock.unlock()
            self.onUnexpectedStop?(error)
        }
    }
}

// MARK: - Helpers

enum DisplayNames {
    static func name(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return "Bildschirm \(displayID)"
    }
}
