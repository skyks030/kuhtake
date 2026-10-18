import AppKit
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case sourceNotFound(String)
    case vuerNotRunning(String)
    case vuerNoWindow(String)
    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let s): return "Quelle „\(s)“ ist derzeit nicht verfügbar."
        case .vuerNotRunning(let app): return "\(app) läuft nicht – Kuhtake verbindet sich, sobald die App gestartet ist"
        case .vuerNoWindow(let app): return "\(app) zeigt kein Fenster – bitte das Vuer-Fenster öffnen"
        }
    }
}

/// Keeps a ScreenCaptureKit stream of the selected window/display running in the background.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "kuhtake.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "kuhtake.capture.audio", qos: .userInteractive)
    private let hub: FrameHub

    /// Called on the main queue when the stream stops unexpectedly (window closed, etc.).
    var onUnexpectedStop: ((Error) -> Void)?

    var isRunning: Bool { stream != nil }

    // ScreenCaptureKit only delivers a picture when the content changes – a still window sends nothing at all.
    // So the last picture is repeated at the frame rate while nothing new comes (video queue only).
    private var repeater: DispatchSourceTimer?
    private var lastFrame: CVPixelBuffer?
    private var lastFramePTS: CMTime = .invalid
    private var lastFrameAt: TimeInterval = 0

    // Kept for changing the picture area while the stream runs.
    private var filter: SCContentFilter?
    private struct Params { var frameRate: FrameRateOption; var captureAudio: Bool; var showCursor: Bool }
    private var params: Params?
    private var crop: CGRect?
    /// True while the crop editor shows the whole window.
    private var showsFullPicture = false

    init(hub: FrameHub) {
        self.hub = hub
        super.init()
    }

    // MARK: Start / stop

    @MainActor
    func start(source: CaptureSource, frameRate: FrameRateOption, captureAudio: Bool, showCursor: Bool) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter = try Self.makeFilter(for: source, content: content)

        crop = source.crop
        params = Params(frameRate: frameRate, captureAudio: captureAudio, showCursor: showCursor)
        let cfg = makeConfig(filter: filter, params: params!)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await s.startCapture()
        startRepeater(interval: frameRate.frameDuration.seconds)
        stream = s
        self.filter = filter
    }

    /// Picture area of the source (nil = all of it); applied to the running stream without restarting it.
    @MainActor
    func setCrop(_ crop: CGRect?) async {
        self.crop = crop
        await updateArea()
    }

    /// Crop editor: show the uncropped window while it is open.
    @MainActor
    func setShowsFullPicture(_ full: Bool) async {
        showsFullPicture = full
        await updateArea()
    }

    @MainActor
    private func updateArea() async {
        guard let stream, let filter, let params else { return }
        try? await stream.updateConfiguration(makeConfig(filter: filter, params: params))
    }

    private func makeConfig(filter: SCContentFilter, params p: Params) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        // Native pixels; limited to the crop (normalized, top-left origin) via `sourceRect`.
        let scale = CGFloat(filter.pointPixelScale)
        let content = filter.contentRect.size
        var area = CGRect(origin: .zero, size: content)
        if !showsFullPicture, let crop = crop?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
           !crop.isNull, crop.width > 0.02, crop.height > 0.02 {
            area = CGRect(x: crop.minX * content.width, y: crop.minY * content.height,
                          width: crop.width * content.width, height: crop.height * content.height)
            cfg.sourceRect = area
        }
        cfg.width = max(2, Int((area.width * scale).rounded()) & ~1)
        cfg.height = max(2, Int((area.height * scale).rounded()) & ~1)
        cfg.minimumFrameInterval = p.frameRate.frameDuration
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 6
        cfg.showsCursor = p.showCursor
        cfg.captureResolution = .best
        cfg.ignoreShadowsSingleWindow = true
        cfg.capturesAudio = p.captureAudio
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        return cfg
    }

    private func startRepeater(interval: TimeInterval) {
        stopRepeater()
        let t = DispatchSource.makeTimerSource(queue: videoQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.repeatIfIdle(interval: interval) }
        t.resume()
        repeater = t
    }

    private func stopRepeater() {
        repeater?.cancel()
        repeater = nil
        videoQueue.async { [weak self] in
            self?.lastFrame = nil
            self?.lastFramePTS = .invalid
        }
    }

    private func repeatIfIdle(interval: TimeInterval) {
        guard let pb = lastFrame, lastFramePTS.isValid else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastFrameAt
        guard elapsed >= interval * 1.5 else { return }
        // Same clock as the real pictures: continue from the last one.
        hub.pushVideo(pb, pts: CMTimeAdd(lastFramePTS, CMTime(seconds: elapsed, preferredTimescale: 1_000_000_000)))
    }

    @MainActor
    func stop() async {
        stopRepeater()
        guard let s = stream else { return }
        stream = nil
        filter = nil
        try? await s.stopCapture()
        hub.reset()
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
        case .vuer:
            let appName = source.appName ?? "Vuer"
            let running = content.applications.contains { VuerApp.isVuer(bundleID: $0.bundleIdentifier, appName: $0.applicationName) }
            let candidates = content.windows.filter { w in
                VuerApp.isVuer(bundleID: w.owningApplication?.bundleIdentifier, appName: w.owningApplication?.applicationName)
                    && w.windowLayer == 0 && w.frame.width > 200 && w.frame.height > 120
            }
            // The biggest window is the monitor; prefer the one on screen.
            guard let window = candidates.filter(\.isOnScreen).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                    ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw running ? CaptureError.vuerNoWindow(appName) : CaptureError.vuerNotRunning(appName)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .decklink, .teradek:
            throw CaptureError.sourceNotFound(source.label)
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
            lastFrame = pb
            lastFramePTS = sampleBuffer.presentationTimeStamp
            lastFrameAt = ProcessInfo.processInfo.systemUptime
            hub.pushVideo(pb, pts: sampleBuffer.presentationTimeStamp)
        case .audio:
            hub.pushAudio(sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stopRepeater()
            self.stream = nil
            self.filter = nil
            self.hub.reset()
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
