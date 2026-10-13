import AVFoundation
import AppKit
import Combine
import SwiftUI

/// The main window: live picture of the current input, or (⌘F) the source browser with two playback monitors.
enum PreviewWindow {
    static let id = "preview"

    static var isVisible: Bool { WindowPresenter.shared.window(id)?.isVisible == true }

    @MainActor
    static func show(mode: PreviewModel.Mode? = nil) {
        let model = PreviewModel.shared
        if let mode { model.setMode(mode) }
        if WindowPresenter.shared.bringToFront(id) { return }
        let hosting = NSHostingController(rootView: PreviewRootView())
        hosting.sizingOptions = [.minSize]
        WindowPresenter.shared.present(id: id, title: "Kuhtake", size: CGSize(width: 1100, height: 680), resizable: true,
                                       controller: hosting, autosaveName: "KuhtakePreview",
                                       onClose: { model.windowClosed() })
        if let w = WindowPresenter.shared.window(id) {
            w.tabbingMode = .disallowed
            w.collectionBehavior.insert(.fullScreenPrimary)
        }
        if model.mode == .browser { model.ensureRoomForBrowser() }
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    static let shared = PreviewModel()

    enum Mode { case live, browser }

    @Published private(set) var mode: Mode = .live
    @Published var showSecondMonitor = false
    @Published var selection: TakeFile.ID?
    /// Take waiting for the "move to trash?" confirmation.
    @Published var deleteRequest: TakeFile?

    let monitor1 = MonitorPlayer()
    let monitor2 = MonitorPlayer(muted: true)

    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Always present the newest take: select it, and show it on monitor 1 unless something else is being looked at.
        ClipIndex.shared.$latest
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] latest in
                guard let self, let latest, self.mode == .browser else { return }
                self.selection = latest.id
                if !self.monitor1.isLoaded || (!self.monitor1.isPlaying && self.monitor1.take?.date ?? .distantPast < latest.date
                                               && self.monitor1.take.map(self.isLastTakeOfShot) != false) {
                    self.monitor1.load(latest)
                }
            }
            .store(in: &cancellables)
    }

    func setMode(_ m: Mode) {
        guard m != mode else {
            if m == .browser { ensureRoomForBrowser() }
            return
        }
        mode = m
        if m == .browser {
            enterBrowser()
        } else {
            monitor1.pause()
            monitor2.pause()
            removeKeyMonitor()
        }
    }

    func windowClosed() {
        monitor1.pause()
        monitor2.pause()
        removeKeyMonitor()
    }

    private func enterBrowser() {
        ClipIndex.shared.rescanSoon(delay: 0)
        if let latest = ClipIndex.shared.latest {
            selection = latest.id
            if !monitor1.isLoaded { monitor1.load(latest) }
        }
        installKeyMonitor()
        ensureRoomForBrowser()
    }

    /// Three panes need some width.
    func ensureRoomForBrowser() {
        guard let w = WindowPresenter.shared.window(PreviewWindow.id), !w.styleMask.contains(.fullScreen),
              let screen = w.screen?.visibleFrame else { return }
        let wanted = min(1320, screen.width)
        guard w.frame.width < wanted - 1 else { return }
        var f = w.frame
        f.size.width = wanted
        f.size.height = max(f.height, min(760, screen.height))
        f.origin.x = max(screen.minX, min(f.minX - (wanted - w.frame.width) / 2, screen.maxX - f.width))
        f.origin.y = max(screen.minY, min(f.minY, screen.maxY - f.height))
        w.setFrame(f, display: true, animate: true)
    }

    func isLastTakeOfShot(_ t: TakeFile) -> Bool {
        ClipIndex.shared.shot(of: t)?.lastTake == t
    }

    var selectedTake: TakeFile? {
        guard let selection else { return nil }
        for scene in ClipIndex.shared.scenes {
            for shot in scene.shots {
                if let t = shot.takes.first(where: { $0.id == selection }) { return t }
            }
        }
        return nil
    }

    func load(into number: Int) {
        guard let take = selectedTake else { NSSound.beep(); return }
        if number == 1 {
            monitor1.load(take)
        } else {
            showSecondMonitor = true
            monitor2.load(take)
        }
    }

    /// Space: both monitors start and stop together.
    func togglePlayBoth() {
        let active = [monitor1] + (showSecondMonitor ? [monitor2] : [])
        if active.contains(where: \.isPlaying) {
            active.forEach { $0.pause() }
        } else {
            active.filter(\.isLoaded).forEach { $0.play() }
        }
    }

    func closeSecondMonitor() {
        monitor2.unload()
        showSecondMonitor = false
    }

    // MARK: Keys

    /// 1 / 2 / Space are plain keys: the list would otherwise use them for type-to-select.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.mode == .browser, event.window?.identifier?.rawValue == PreviewWindow.id else { return event }
            // Leave typing in text fields alone.
            if let tv = event.window?.firstResponder as? NSTextView, tv.isEditable { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            // ⌫ / ⌘⌫: selected take into the trash (after asking).
            if [51, 117].contains(Int(event.keyCode)), mods.isEmpty || mods == .command {
                guard let take = self.selectedTake else { return event }
                self.deleteRequest = take
                return nil
            }
            guard mods.isEmpty else { return event }
            switch Int(event.keyCode) {
            case 18, 83: self.load(into: 1); return nil    // 1, keypad 1
            case 19, 84: self.load(into: 2); return nil    // 2, keypad 2
            case 49: self.togglePlayBoth(); return nil     // space
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Root

struct PreviewRootView: View {
    @ObservedObject private var model = PreviewModel.shared
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        VStack(spacing: 0) {
            PreviewTopBar()
            Divider()
            Group {
                switch model.mode {
                case .live: LivePane()
                case .browser: SourceBrowserView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Source, connection state, mode switch and the record button – visible in both modes.
private struct PreviewTopBar: View {
    @ObservedObject private var model = PreviewModel.shared
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sourceIcon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("INPUT-QUELLE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(settings.source?.label ?? "Keine Quelle gewählt")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(stateText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Menu {
                SourceMenuItems()
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Quelle wechseln")

            Spacer(minLength: 12)

            Picker("", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Source Browser").tag(PreviewModel.Mode.browser)
                Text("Live").tag(PreviewModel.Mode.live)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Source Browser (\(shortcutText(.sourceBrowser))) · Live-Bild (\(shortcutText(.liveView)))")

            Spacer(minLength: 12)

            if settings.autoRecordEnabled {
                Text("AUTO").font(.caption.weight(.heavy)).foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Color.orange.opacity(0.7)))
                    .help("Auto-Aufnahme ist aktiv")
            }
            NextClipButton()
            RecordButton()
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var sourceIcon: String {
        switch settings.source?.kind {
        case .decklink: return "cable.connector.horizontal"
        case .display: return "display"
        case .window: return "macwindow"
        case .vuer: return "antenna.radiowaves.left.and.right"
        case nil: return "video.slash"
        }
    }

    private var stateColor: Color {
        switch controller.captureState {
        case .running: return controller.isRecording ? .red : .green
        case .starting: return .yellow
        case .noSource: return .gray
        case .unavailable, .noPermission: return .orange
        }
    }

    private var stateText: String {
        let h = controller.health
        switch controller.captureState {
        case .running:
            var parts: [String] = []
            if let f = h.signalFormat { parts.append(f) }
            parts.append(String(format: "%.0f fps", h.fps))
            if h.reconnects > 0 { parts.append("\(h.reconnects)× neu verbunden") }
            return "Verbunden · " + parts.joined(separator: " · ")
        case .starting: return "Verbinde …"
        case .noSource: return "Über das Menü eine Quelle wählen"
        case .unavailable(let why): return why
        case .noPermission: return "Bildschirmaufnahme-Berechtigung fehlt"
        }
    }
}

/// Name of the next clip; click to set scene, shot and take right there.
private struct NextClipButton: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var editing = false

    var body: some View {
        Button {
            editing.toggle()
        } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Text("NÄCHSTER CLIP").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Text(ClipNaming.nextFileName)
                        .font(.system(.caption, design: .monospaced))
                    Image(systemName: "pencil").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(editing ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Szene, Shot und Take des nächsten Clips ändern (\(shortcutText(.nameNextClip)))")
        .popover(isPresented: $editing, arrowEdge: .bottom) { NextClipEditor() }
    }
}

/// Edits the counter for the next clip directly (same values as „Szene / Shot / Take festlegen …“).
private struct NextClipEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var sceneFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nächster Clip").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Szene").gridColumnAlignment(.trailing)
                    TextField("z. B. 12A", text: Binding(get: { settings.scene }, set: { new in
                        if new != settings.scene { settings.take = 1 }
                        settings.scene = new
                    }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($sceneFocused)
                }
                GridRow {
                    Text("Shot")
                    Stepper(value: Binding(get: { settings.shot }, set: { settings.shot = $0; settings.take = 1 }), in: 1...99) {
                        Text(ClipName.twoDigits(settings.shot)).font(.body.monospacedDigit()).frame(width: 34, alignment: .leading)
                    }
                    .disabled(!ClipNaming.scheme.hasShot)
                }
                GridRow {
                    Text("Take")
                    Stepper(value: $settings.take, in: 1...999) {
                        Text(ClipName.twoDigits(settings.take)).font(.body.monospacedDigit()).frame(width: 34, alignment: .leading)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(ClipNaming.previewPath(for: ClipNaming.next))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("Namensschema …") { SettingsWindow.show(tab: .naming) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(16)
        .frame(minWidth: 280)
        .onAppear { sceneFocused = true }
    }
}

func shortcutText(_ a: ShortcutAction) -> String {
    AppSettings.shared.shortcut(for: a).combo?.display ?? "–"
}

/// Quick source switch: DeckLink devices, plus the full picker for windows/screens.
struct SourceMenuItems: View {
    @ObservedObject private var directory = DeckLinkDirectory.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Section("Blackmagic DeckLink") {
            if !directory.driverAvailable {
                Text("Desktop Video nicht installiert")
            } else if directory.devices.isEmpty {
                Text("Kein Gerät angeschlossen")
            }
            ForEach(directory.devices) { d in
                Button {
                    AppController.shared.select(source: .deckLink(d))
                } label: {
                    if settings.source?.kind == .decklink && settings.source?.deckLinkID == d.id {
                        Label(d.name, systemImage: "checkmark")
                    } else {
                        Text(d.name)
                    }
                }
            }
        }
        Section("Teradek") {
            Button {
                AppController.shared.select(source: .vuer())
            } label: {
                if settings.source?.kind == .vuer {
                    Label("Vuer HDR (App-Fenster)", systemImage: "checkmark")
                } else {
                    Text("Vuer HDR (App-Fenster)")
                }
            }
        }
        Divider()
        Button("Fenster oder Bildschirm wählen …") { SourcePickerWindow.show() }
        if settings.source?.isScreenCapture == true {
            Button("Bildausschnitt festlegen …") { CropWindow.show() }
        }
    }
}

struct RecordButton: View {
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        Button {
            controller.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: controller.isRecording ? "stop.fill" : "circle.fill")
                    .foregroundStyle(controller.isRecording ? .white : .red)
                if let start = controller.recordingStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Self.format(ctx.date.timeIntervalSince(start)))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                    }
                } else {
                    Text("REC").font(.callout.weight(.bold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(controller.isRecording ? .white : .primary)
            .background(Capsule().fill(controller.isRecording ? Color.red : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!controller.isRecording && controller.captureState != .running)
        .help("Aufnahme starten / stoppen (\(shortcutText(.toggleRecording)))")
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

// MARK: - Live

private struct LivePane: View {
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TimecodeBar()
            Divider()
            ZStack {
                Color.black
                LiveVideoView()
                    .opacity(controller.captureState == .running ? 1 : 0.25)
                if controller.captureState != .running {
                    statusOverlay
                }
                if controller.isRecording {
                    Rectangle().strokeBorder(Color.red, lineWidth: 3)
                }
            }
            HStack(spacing: 14) {
                AudioMeterView(meter: controller.hub.meter)
                    .frame(maxWidth: 360)
                Spacer()
                if let msg = controller.lastMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 12) {
            Image(nsImage: CowArt.illustration(size: 84)).opacity(0.9)
            switch controller.captureState {
            case .noSource:
                Text("Noch keine Quelle gewählt").font(.title3.weight(.semibold))
                Text("Wähle einen Blackmagic-Eingang, Teradek Vuer, ein Fenster oder einen Bildschirm.")
                    .foregroundStyle(.white.opacity(0.7))
                Menu("Quelle wählen") { SourceMenuItems() }.fixedSize()
            case .starting:
                ProgressView().controlSize(.small)
                Text("Verbinde mit \(settings.source?.label ?? "Quelle") …")
            case .unavailable(let why):
                ProgressView().controlSize(.small)
                Text(why).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text("Die Verbindung wird laufend überwacht und automatisch wiederhergestellt.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
            case .noPermission:
                Text("Bildschirmaufnahme-Berechtigung fehlt").font(.title3.weight(.semibold))
                Button("Berechtigungen einrichten …") { PermissionsWindow.show() }
            case .running:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(30)
    }
}

/// Shows every incoming picture as it arrives (AVSampleBufferDisplayLayer handles YUV and BGRA, with color management).
struct LiveVideoView: NSViewRepresentable {
    func makeNSView(context: Context) -> LiveVideoNSView { LiveVideoNSView() }
    func updateNSView(_ nsView: LiveVideoNSView, context: Context) {}
}

final class LiveVideoNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "kuhtake.preview.display", qos: .userInteractive)
    private var observer: UUID?
    private var format: CMVideoFormatDescription?
    private var pending = false
    private let pendingLock = NSLock()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let hub = AppController.shared.hub
        if window != nil, observer == nil {
            observer = hub.addVideoObserver { [weak self] pb, _ in self?.enqueue(pb) }
            if let pb = hub.latestPixelBuffer { enqueue(pb) }
        } else if window == nil, let observer {
            hub.removeVideoObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer { AppController.shared.hub.removeVideoObserver(observer) }
    }

    /// Capture thread → display queue; drops pictures while the previous one is still being handed over.
    private func enqueue(_ pb: CVPixelBuffer) {
        let skip = pendingLock.withLock { () -> Bool in
            if pending { return true }
            pending = true
            return false
        }
        if skip { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.pendingLock.withLock { self.pending = false } }
            if self.format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(self.format!, imageBuffer: pb) {
                var f: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &f)
                self.format = f
            }
            guard let format = self.format else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                           sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            let renderer = self.displayLayer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
            renderer.enqueue(sb)
        }
    }
}

/// Peak meters per channel, green → yellow → red.
struct AudioMeterView: View {
    @ObservedObject var meter: AudioMeter

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: meter.levels.isEmpty ? "speaker.slash" : "speaker.wave.2")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(spacing: 3) {
                if meter.levels.isEmpty {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
                } else {
                    ForEach(Array(meter.levels.prefix(2).enumerated()), id: \.offset) { _, db in
                        bar(db)
                    }
                }
            }
        }
        .help("Pegel der Quelle")
    }

    private func bar(_ db: Float) -> some View {
        GeometryReader { geo in
            let level = CGFloat((db - AudioMeter.floor) / -AudioMeter.floor)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * max(0, min(1, level))) }
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.08), value: db)
    }
}
