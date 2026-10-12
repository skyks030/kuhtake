import AppKit
import Combine
import CoreGraphics

/// Central coordinator: capture stream, recording, auto-trigger and naming.
final class AppController: ObservableObject {
    static let shared = AppController()

    enum CaptureState: Equatable {
        case noSource, starting, running, unavailable(String), noPermission
    }

    let settings = AppSettings.shared
    let engine = CaptureEngine()
    let detector = MotionDetector()

    @Published private(set) var captureState: CaptureState = .noSource
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var lastMessage: String?

    private var recorder: Recorder?
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var restartWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    /// True while the auto-record setup window is open, so adjusting the region doesn't start takes.
    var autoTriggerSuspended = false

    private init() {
        engine.onUnexpectedStop = { [weak self] error in self?.handleStreamLoss(error) }
        detector.pixelBufferProvider = { [weak self] in self?.engine.latestPixelBuffer }
        detector.onTrigger = { [weak self] active in self?.handleAutoTrigger(active) }

        // Keep the detector's parameter snapshot in sync.
        Publishers.MergeMany(
            settings.$region.map { _ in () }.eraseToAnyPublisher(),
            settings.$regionShape.map { _ in () }.eraseToAnyPublisher(),
            settings.$sensitivity.map { _ in () }.eraseToAnyPublisher(),
            settings.$startDelay.map { _ in () }.eraseToAnyPublisher(),
            settings.$stopDelay.map { _ in () }.eraseToAnyPublisher(),
            settings.$baseline.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.detector.refreshParams() }
        .store(in: &cancellables)

        // Stream parameters changed → restart the background capture (not while recording).
        Publishers.CombineLatest3(settings.$frameRate, settings.$recordAudio, settings.$showCursor)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRestart() }
            .store(in: &cancellables)
    }

    // MARK: Capture

    func startup() {
        guard CGPreflightScreenCaptureAccess() else {
            captureState = .noPermission
            return
        }
        restartCapture()
    }

    func select(source: CaptureSource) {
        if isRecording { stopRecording() }
        settings.source = source
        settings.baseline = nil
        restartCapture()
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isRecording { self.scheduleRestart() } else { self.restartCapture() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func restartCapture() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let source = settings.source else {
            captureState = .noSource
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            captureState = .noPermission
            return
        }
        captureState = .starting
        let s = settings
        let previous = captureTask
        captureTask = Task { @MainActor in
            await previous?.value
            do {
                try await engine.start(source: source, frameRate: s.frameRate, captureAudio: s.recordAudio, showCursor: s.showCursor)
                self.captureState = .running
                self.detector.start()
            } catch {
                self.captureState = .unavailable(error.localizedDescription)
                self.scheduleRetry()
            }
        }
    }

    private func handleStreamLoss(_ error: Error) {
        if isRecording { stopRecording() }
        captureState = .unavailable(error.localizedDescription)
        scheduleRetry()
    }

    /// The watched window may come back (e.g. viewer app restarted) – keep trying.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, !self.engine.isRunning, self.settings.source != nil else { return }
            self.restartCapture()
        }
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        guard captureState == .running else {
            notify("Keine aktive Quelle – bitte zuerst eine Quelle wählen.")
            return
        }
        let s = settings
        let container = s.effectiveContainer
        do {
            let url = try ClipNaming.tempFolder()
                .appendingPathComponent("rec-\(UUID().uuidString)")
                .appendingPathExtension(container.fileExtension)
            let rec = Recorder(url: url, config: .init(
                container: container, codec: s.codec, resolution: s.resolution,
                frameRate: s.frameRate, bitrateMbps: s.bitrateMbps, audio: s.recordAudio))
            recorder = rec
            engine.sink = rec
            isRecording = true
            recordingStartedAt = Date()
        } catch {
            notify("Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording, let rec = recorder else { return }
        engine.sink = nil
        recorder = nil
        isRecording = false
        recordingStartedAt = nil
        rec.finish { [weak self] result in
            switch result {
            case .success(let r):
                self?.handleFinishedClip(r)
            case .failure(let error):
                self?.notify("Aufnahme fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func handleFinishedClip(_ result: Recorder.Result) {
        if settings.showNamingPrompt {
            NamingPanelController.shared.enqueue(clip: result)
        } else {
            let name = ClipNaming.next
            save(clip: result.url, as: name)
        }
    }

    /// Called by the naming panel or directly in automatic mode.
    @discardableResult
    func save(clip url: URL, as name: ClipName) -> URL? {
        do {
            let target = try ClipNaming.store(tempFile: url, as: name)
            ClipNaming.advance(after: name)
            lastMessage = "Gespeichert: \(target.lastPathComponent)"
            return target
        } catch {
            notify("Datei konnte nicht gespeichert werden (\(error.localizedDescription)). Sie liegt noch unter \(url.path).")
            return nil
        }
    }

    func discard(clip url: URL) {
        try? FileManager.default.removeItem(at: url)
        lastMessage = "Clip verworfen"
    }

    // MARK: Auto recording

    private func handleAutoTrigger(_ active: Bool) {
        guard settings.autoRecordEnabled, !autoTriggerSuspended, captureState == .running else { return }
        if active { startRecording() } else { stopRecording() }
    }

    func setAutoRecord(_ enabled: Bool) {
        settings.autoRecordEnabled = enabled
        if enabled, !autoTriggerSuspended, detector.isActive, !isRecording { startRecording() }
    }

    // MARK: Messages

    func notify(_ message: String) {
        lastMessage = message
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kuhtake"
        alert.informativeText = message
        alert.runModal()
    }
}
