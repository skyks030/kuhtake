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
    /// Every input delivers here; recorder, detector and previews read from it.
    let hub = FrameHub()
    private(set) lazy var engine = CaptureEngine(hub: hub)
    private(set) lazy var deckLink = DeckLinkEngine(hub: hub)
    private(set) lazy var stream = TeradekStreamEngine(hub: hub)
    let detector = MotionDetector()
    let timecode = TimecodeReader()

    @Published private(set) var captureState: CaptureState = .noSource
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var lastMessage: String?

    /// Connection health, refreshed once a second.
    struct Health: Equatable {
        var fps: Double = 0
        /// Seconds since the last picture.
        var frameAge: TimeInterval = .infinity
        var signalFormat: String?
        var deviceName: String?
        var reconnects = 0
        /// Network stream: statistics lines (transport, packets, decoder).
        var streamDetails: [String] = []
    }
    @Published private(set) var health = Health()
    private var healthTimer: Timer?
    private var lastHealthTick = ProcessInfo.processInfo.systemUptime

    private var recorder: Recorder?
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var restartWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    /// Copies finished takes into the project folder, one after the other.
    private let storeQueue = DispatchQueue(label: "kuhtake.store", qos: .userInitiated)
    /// Recordings being finished plus copies into the project folder still running (main queue).
    private var pendingWrites = 0
    /// Quitting now would cut off a take or a copy.
    var hasPendingWrites: Bool { isRecording || pendingWrites > 0 }
    /// True while the auto-record setup window is open, so adjusting the region doesn't start takes.
    var autoTriggerSuspended = false

    private init() {
        engine.onUnexpectedStop = { [weak self] error in self?.handleStreamLoss(error) }
        deckLink.onStateChange = { [weak self] state in self?.handleDeckLinkState(state) }
        stream.onStateChange = { [weak self] state in self?.handleStreamState(state) }
        detector.pixelBufferProvider = { [weak self] in self?.hub.latestPixelBuffer }
        detector.onTrigger = { [weak self] active in self?.handleAutoTrigger(active) }
        timecode.pixelBufferProvider = { [weak self] in self?.hub.latestPixelBuffer }

        Publishers.MergeMany(
            settings.$timecodeEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$timecodeRegion.map { _ in () }.eraseToAnyPublisher(),
            settings.$frameRate.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.timecode.refreshParams() }
        .store(in: &cancellables)

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
        // (DeckLink and network streams deliver their own format; these only concern screen capture.)
        Publishers.CombineLatest3(settings.$frameRate, settings.$recordAudio, settings.$showCursor)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.settings.source?.isScreenCapture != false else { return }
                self?.scheduleRestart()
            }
            .store(in: &cancellables)
    }

    // MARK: Capture

    func startup() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkHealth() }
        timecode.start()
        restartCapture()
        let unsaved = TempRecordings.unsaved()
        if !unsaved.isEmpty {
            lastMessage = "\(unsaved.count) nicht gespeicherte Aufnahme(n) in \(TempRecordings.folder.path) – Endung .tmp in .mov ändern, um sie abzuspielen"
        }
    }

    func select(source: CaptureSource) {
        if isRecording { stopRecording() }
        var source = source
        // Keep the picture area that was set for this input.
        if source.crop == nil {
            if let current = settings.source, current.isSame(as: source) { source.crop = current.crop }
            else if source.kind == .vuer { source.crop = settings.vuerCrop }
        }
        if let current = settings.source, current.isSame(as: source) {
            settings.source = source
            if captureState != .running { restartCapture() }
            return
        }
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
            deckLink.stop()
            stream.stop()
            stopScreenCapture()
            captureState = .noSource
            return
        }
        if source.kind == .teradek {
            stopScreenCapture()
            deckLink.stop()
            stream.start(address: source.streamURL ?? "")
            handleStreamState(stream.state)
            detector.start()
            return
        }
        stream.stop()
        if source.kind == .decklink {
            stopScreenCapture()
            deckLink.start(deviceID: source.deckLinkID)
            handleDeckLinkState(deckLink.state)
            detector.start()
            return
        }
        deckLink.stop()
        guard CGPreflightScreenCaptureAccess() else {
            captureState = .noPermission
            return
        }
        captureState = .starting
        let s = settings
        let previous = captureTask
        captureTask = Task { @MainActor in
            await previous?.value
            // Switched to another input in the meantime.
            guard self.settings.source.map({ $0.isSame(as: source) }) == true else { return }
            do {
                try await engine.start(source: source, frameRate: s.frameRate, captureAudio: s.recordAudio, showCursor: s.showCursor)
                self.captureState = .running
                self.detector.start()
                if source.kind == .vuer, source.crop == nil { self.detectVuerArea() }
            } catch {
                self.captureState = .unavailable(error.localizedDescription)
                self.scheduleRetry()
            }
        }
    }

    // MARK: Picture area (window / screen / VUER)

    /// Only this part of the captured window or screen is used (nil = all of it).
    func setCrop(_ crop: CGRect?) {
        guard var source = settings.source, source.isScreenCapture else { return }
        source.crop = crop
        settings.source = source
        if source.kind == .vuer { settings.vuerCrop = crop }
        // The auto-record region now looks at a different picture.
        settings.baseline = nil
        Task { @MainActor in await engine.setCrop(crop) }
    }

    /// While the area editor is open the whole window is shown (and auto recording paused).
    func setCropEditing(_ editing: Bool) {
        autoTriggerSuspended = editing
        Task { @MainActor in await engine.setShowsFullPicture(editing) }
    }

    /// Finds VUER's video area once the first pictures of its window have arrived.
    private func detectVuerArea() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.settings.source?.kind == .vuer, self.settings.source?.crop == nil,
                  let pb = self.hub.latestPixelBuffer, let area = VideoAreaDetector.detect(in: pb) else { return }
            // Only worth it if there is a real border around the picture.
            guard area.width < 0.98 || area.height < 0.98 else { return }
            self.setCrop(area)
            self.lastMessage = "Videobereich im Vuer-Fenster erkannt – anpassbar über „Bildausschnitt festlegen …“"
        }
    }

    private func stopScreenCapture() {
        guard engine.isRunning || captureTask != nil else { return }
        let previous = captureTask
        captureTask = Task { @MainActor in
            await previous?.value
            await self.engine.stop()
        }
    }

    // MARK: DeckLink

    private func handleDeckLinkState(_ state: DeckLinkEngine.State) {
        guard settings.source?.kind == .decklink else { return }
        let device = deckLink.activeDeviceName ?? DeckLinkDirectory.shared.name(for: settings.source?.deckLinkID) ?? "DeckLink"
        switch state {
        case .running:
            captureState = .running
        case .starting:
            captureState = .starting
        case .noSignal:
            // A recording keeps going through short signal drops (the recorder holds the last picture);
            // `checkHealth` ends it if the signal stays away.
            captureState = .unavailable("Kein Signal am Eingang von \(device)")
        case .waitingForDevice:
            if isRecording { stopRecording() }
            captureState = .unavailable(DeckLinkDirectory.shared.driverAvailable
                ? "DeckLink-Gerät nicht verbunden – wird automatisch verbunden, sobald es da ist"
                : "Blackmagic Desktop Video ist nicht installiert")
        case .inUse:
            if isRecording { stopRecording() }
            captureState = .unavailable("\(device) wird von einer anderen App benutzt – neuer Versuch läuft")
        case .failed:
            if isRecording { stopRecording() }
            captureState = .unavailable("\(device) konnte nicht gestartet werden – neuer Versuch läuft")
        }
    }

    // MARK: Teradek network stream

    /// Connects to a Teradek encoder's stream (encoder IP or stream URL, see `StreamAddress`) and remembers the address.
    func connectStream(_ raw: String, name: String? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = StreamAddress.parse(text) else {
            notify("„\(text)“ ist keine gültige Stream-Adresse. Möglich sind die IP des Encoders oder rtsp://…, udp://@:Port, tcp://IP:Port bzw. http://…m3u8.")
            return
        }
        var recent = settings.recentStreamAddresses.filter { $0 != text }
        recent.insert(text, at: 0)
        settings.recentStreamAddresses = Array(recent.prefix(8))
        select(source: .teradek(address: text, name: name ?? address.shortName))
    }

    func forgetStreamAddress(_ raw: String) {
        settings.recentStreamAddresses.removeAll { $0 == raw }
    }

    private func handleStreamState(_ state: TeradekStreamEngine.State) {
        guard settings.source?.kind == .teradek else { return }
        switch state {
        case .idle, .connecting:
            captureState = .starting
        case .running:
            captureState = .running
        case .waiting(let why):
            // A recording keeps going through short drops (the recorder holds the last picture);
            // `checkHealth` ends it if the stream stays away.
            captureState = .unavailable(why)
        case .failed(let why, let retrying):
            if !retrying, isRecording { stopRecording() }
            captureState = .unavailable(retrying ? why + " – neuer Versuch läuft" : why)
        }
    }

    /// Once a second: frame rate for the preview, and the watchdog for hardware inputs.
    private func checkHealth() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - lastHealthTick)
        lastHealthTick = now
        var h = Health()
        h.fps = Double(hub.takeFrameCount()) / elapsed
        h.frameAge = hub.lastFrameAge

        if settings.source?.kind == .decklink {
            h.signalFormat = deckLink.signalFormat
            h.deviceName = deckLink.activeDeviceName
            h.reconnects = deckLink.restartCount
            // The input supervision restarts a stalled stream after 3 s. If pictures still don't come although
            // the input says it runs, the capture itself is stuck: start over completely.
            if deckLink.state == .running, h.frameAge > 6 {
                deckLink.forceRestart()
            }
        }
        if settings.source?.kind == .teradek {
            h.signalFormat = stream.signalFormat
            h.reconnects = stream.reconnects
            h.streamDetails = stream.diagnostics
        }
        // Signal gone for good during a take: close the file instead of recording a frozen picture.
        if settings.source?.kind == .decklink || settings.source?.kind == .teradek, isRecording, h.frameAge > 10 {
            stopRecording()
            lastMessage = "Aufnahme beendet – kein Signal mehr"
        }
        if h != health { health = h }
    }

    private func handleStreamLoss(_ error: Error) {
        guard settings.source?.needsScreenCapturePermission == true else { return }
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
            // The temp files of takes stored before are replaced by this one.
            TempRecordings.removeHandled()
            let url = try TempRecordings.newFile()
            let rec = Recorder(url: url, config: .init(
                container: container, codec: s.codec, resolution: s.resolution,
                frameRate: s.frameRate, bitrateMbps: s.bitrateMbps, audio: s.recordAudio,
                timecode: s.timecodeEnabled ? { [timecode] in timecode.startFrames() } : nil))
            timecode.setRecording(true)
            recorder = rec
            hub.sink = rec
            isRecording = true
            recordingStartedAt = Date()
        } catch {
            notify("Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording, let rec = recorder else { return }
        hub.sink = nil
        recorder = nil
        isRecording = false
        timecode.setRecording(false)
        recordingStartedAt = nil
        pendingWrites += 1
        rec.finish { [weak self] result in
            defer { self?.pendingWrites -= 1 }
            switch result {
            case .success(let r):
                self?.handleFinishedClip(r)
            case .failure(let error):
                let kept = FileManager.default.fileExists(atPath: rec.url.path)
                self?.notify("Aufnahme fehlgeschlagen: \(error.localizedDescription)"
                             + (kept ? "\n\nDas bis dahin Aufgenommene liegt unter \(rec.url.path) – Endung .tmp in .mov ändern, um es abzuspielen." : ""))
            }
        }
    }

    private func handleFinishedClip(_ result: Recorder.Result) {
        if settings.showNamingPrompt {
            NamingPanelController.shared.enqueue(clip: result)
        } else {
            let name = ClipNaming.next
            save(clip: result, as: name)
        }
    }

    /// Called by the naming panel or directly in automatic mode. Copies the take into the project folder in the
    /// background and checks the copy; the temp file is kept (and marked) until the next recording starts.
    func save(clip: Recorder.Result, as name: ClipName) {
        // The counter moves on right away, so the next take already gets the following name.
        ClipNaming.advance(after: name)
        lastMessage = "Speichere \(ClipNaming.scheme.relativePath(for: name)) …"
        pendingWrites += 1
        storeQueue.async {
            defer { DispatchQueue.main.async { self.pendingWrites -= 1 } }
            do {
                let target = try ClipNaming.store(tempFile: clip.url, as: name, fileExtension: clip.fileExtension)
                TempRecordings.markStored(clip.url, as: target)
                DispatchQueue.main.async {
                    self.lastMessage = "Gespeichert: \(target.lastPathComponent)"
                    ClipIndex.shared.rescanSoon()
                }
            } catch {
                DispatchQueue.main.async {
                    self.notify("Datei konnte nicht im Projektordner gespeichert werden (\(error.localizedDescription)). "
                                + "Die Aufnahme liegt unverändert unter \(clip.url.path) – Endung .tmp in .\(clip.fileExtension) ändern, um sie zu verwenden.")
                }
            }
        }
    }

    func discard(clip url: URL) {
        TempRecordings.markDiscarded(url)
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

    /// Quits, finishing a running recording first.
    func quitSafely() {
        stopRecording()
        whenWritesDone { NSApp.terminate(nil) }
    }

    /// Runs `done` once no take is being finished or copied any more.
    func whenWritesDone(_ done: @escaping () -> Void) {
        guard hasPendingWrites else { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.whenWritesDone(done) }
    }

    // MARK: Messages

    /// Status line only, no alert.
    func showMessage(_ message: String) {
        lastMessage = message
    }

    func notify(_ message: String) {
        lastMessage = message
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kuhtake"
        alert.informativeText = message
        alert.runModal()
    }
}
