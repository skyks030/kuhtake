import AppKit
import ServiceManagement
import SwiftUI

/// ⌘, – everything from the status menu, in tabs.
enum SettingsWindow {
    static let id = "settings"

    enum Tab: Int, CaseIterable {
        case general, source, recording, auto, timecode, naming, shortcuts

        var title: String {
            switch self {
            case .general: return "Allgemein"
            case .source: return "Quelle"
            case .recording: return "Aufnahme"
            case .auto: return "Auto-Aufnahme"
            case .timecode: return "Timecode"
            case .naming: return "Benennung"
            case .shortcuts: return "Tastenkürzel"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .source: return "video"
            case .recording: return "film"
            case .auto: return "wand.and.rays"
            case .timecode: return "clock"
            case .naming: return "number"
            case .shortcuts: return "keyboard"
            }
        }

        @MainActor @ViewBuilder
        var view: some View {
            switch self {
            case .general: GeneralSettingsView()
            case .source: SourceSettingsView()
            case .recording: FormatView()
            case .auto: AutoSettingsView()
            case .timecode: TimecodeSettingsView()
            case .naming: NamingSettingsView()
            case .shortcuts: ShortcutSettingsView()
            }
        }
    }

    @MainActor
    static func show(tab: Tab? = nil) {
        if let existing = WindowPresenter.shared.window(id), let tabs = existing.contentViewController as? NSTabViewController {
            if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
            WindowPresenter.shared.bringToFront(id)
            return
        }
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for t in Tab.allCases {
            let hosting = NSHostingController(rootView: t.view)
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = t.title
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            tabs.addTabViewItem(item)
        }
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        WindowPresenter.shared.present(id: id, title: "Einstellungen", size: CGSize(width: 600, height: 460), resizable: false,
                                       controller: tabs)
        if let w = WindowPresenter.shared.window(id) {
            w.toolbarStyle = .preference
            w.styleMask.remove(.miniaturizable)
        }
    }
}

// MARK: - Allgemein

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Arbeitsordner") {
                LabeledContent("Ablage") {
                    Text((settings.workingFolder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Im Finder zeigen") {
                        try? FileManager.default.createDirectory(at: settings.workingFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(settings.workingFolder)
                    }
                    Button("Ändern …") { WorkingFolder.choose() }
                }
            }
            Section("Programm") {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        AppController.shared.notify("Autostart konnte nicht geändert werden: \(error.localizedDescription)")
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                LabeledContent("Version") {
                    HStack {
                        Text(Updater.currentVersion).monospacedDigit()
                        Button("Nach Updates suchen …") { Updater.shared.check(userInitiated: true) }
                    }
                }
            }
            Section {
                Text("Das Vorschaufenster öffnet sich bei jedem Start. Ist es geschlossen, lebt Kuhtake nur in der Menüleiste – über das Kuh-Symbol oder \(shortcutText(.showPreview)) holst du es zurück.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}

enum WorkingFolder {
    static func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Als Arbeitsordner wählen"
        panel.directoryURL = AppSettings.shared.workingFolder
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.shared.workingFolder = url
        }
    }
}

// MARK: - Quelle

private struct SourceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var directory = DeckLinkDirectory.shared

    var body: some View {
        Form {
            Section("Aktive Quelle") {
                LabeledContent("Quelle", value: settings.source?.label ?? "–")
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(controller.captureState == .running ? Color.green : .orange).frame(width: 8, height: 8)
                        Text(statusText).multilineTextAlignment(.trailing)
                    }
                }
                if controller.captureState == .running {
                    if let f = controller.health.signalFormat { LabeledContent("Signal", value: f) }
                    LabeledContent("Bildrate", value: String(format: "%.1f fps", controller.health.fps))
                }
                if settings.source?.kind == .decklink {
                    LabeledContent("Neu verbunden", value: "\(controller.health.reconnects)×")
                }
            }

            Section {
                if !directory.driverAvailable {
                    Label("Blackmagic Desktop Video ist nicht installiert.", systemImage: "exclamationmark.triangle")
                    Link("Desktop Video herunterladen", destination: URL(string: "https://www.blackmagicdesign.com/support/family/capture-and-playback")!)
                } else if directory.devices.isEmpty {
                    Label("Kein DeckLink- oder UltraStudio-Gerät angeschlossen.", systemImage: "cable.connector.slash")
                        .foregroundStyle(.secondary)
                }
                ForEach(directory.devices) { d in
                    let active = settings.source?.kind == .decklink && settings.source?.deckLinkID == d.id
                    HStack {
                        Image(systemName: "cable.connector.horizontal").foregroundStyle(active ? Color.accentColor : .secondary)
                        Text(d.name)
                        Spacer()
                        if active {
                            Text("Aktiv").foregroundStyle(.secondary)
                        } else {
                            Button("Verwenden") { controller.select(source: .deckLink(d)) }
                        }
                    }
                }
            } header: {
                Text("Blackmagic DeckLink / UltraStudio")
            } footer: {
                Text("Bild und Ton kommen direkt über das DeckLink SDK (nicht als Webcam). Das Signalformat wird automatisch erkannt. Die Verbindung wird jede Sekunde geprüft: Zieht man das Gerät ab, bricht das Signal ab oder liefert der Eingang keine Bilder mehr, verbindet Kuhtake sich selbstständig neu.\(directory.driverVersion.map { " Desktop Video \($0)." } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VuerSettingsSection()
            StreamSettingsSection()

            Section("Bildschirm & Fenster") {
                HStack {
                    Text("Ein Fenster oder einen ganzen Bildschirm abfilmen.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Auswählen …") { SourcePickerWindow.show() }
                }
                if settings.source?.isScreenCapture == true {
                    LabeledContent("Bildausschnitt") {
                        HStack {
                            Text(settings.source?.crop.map { String(format: "%.0f × %.0f %% des Fensters", $0.width * 100, $0.height * 100) } ?? "ganzes Bild")
                                .foregroundStyle(.secondary)
                            Button("Festlegen …") { CropWindow.show() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    private var statusText: String {
        switch controller.captureState {
        case .noSource: return "Keine Quelle"
        case .starting: return "Verbinde …"
        case .running: return controller.isRecording ? "Aufnahme läuft" : "Verbunden"
        case .unavailable(let why): return why
        case .noPermission: return "Bildschirmaufnahme-Berechtigung fehlt"
        }
    }
}

// MARK: - Auto-Aufnahme

private struct AutoSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Aufnahme aktiv", isOn: Binding(get: { settings.autoRecordEnabled }, set: { controller.setAutoRecord($0) }))
                LabeledContent("Bereich") {
                    Button("Im Live-Bild festlegen …") { AutoRecordWindow.show() }
                }
                Picker("Form des Bereichs", selection: $settings.regionShape) {
                    ForEach(RegionShape.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Weicht der überwachte Bereich (z. B. die REC-Anzeige der Kamera) deutlich vom gespeicherten Ruhezustand ab, startet die Aufnahme – kehrt er zurück, stoppt sie.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auslösung") {
                LabeledContent("Empfindlichkeit") {
                    HStack {
                        Text("gering").font(.caption)
                        Slider(value: $settings.sensitivity, in: 0...1)
                        Text("hoch").font(.caption)
                    }
                }
                LabeledContent("Start-Verzögerung") {
                    HStack {
                        Slider(value: tenths($settings.startDelay), in: 0...3)
                        Text(String(format: "%.1f s", settings.startDelay)).monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("Stopp-Verzögerung") {
                    HStack {
                        Slider(value: tenths($settings.stopDelay), in: 0...10)
                        Text(String(format: "%.1f s", settings.stopDelay)).monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("Ruhezustand") {
                    Text(settings.baseline == nil ? "nicht gespeichert" : "gespeichert").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    private func tenths(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = ($0 * 10).rounded() / 10 })
    }
}

// MARK: - Teradek

private struct StreamSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared
    @State private var copied = false

    var body: some View {
        Section {
            StreamAddressField()
            if settings.source?.kind == .teradek {
                LabeledContent("Neu verbunden", value: "\(controller.health.reconnects)×")
                ForEach(controller.health.streamDetails, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !settings.recentStreamAddresses.isEmpty {
                ForEach(settings.recentStreamAddresses, id: \.self) { a in
                    let active = settings.source?.kind == .teradek && settings.source?.streamURL == a
                    HStack {
                        Image(systemName: "network").foregroundStyle(active ? Color.accentColor : .secondary)
                        Text(StreamAddress.parse(a)?.displayName ?? a).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if active {
                            Text("Aktiv").foregroundStyle(.secondary)
                        } else {
                            Button("Verwenden") { controller.connectStream(a) }
                            Button {
                                controller.forgetStreamAddress(a)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Aus der Liste entfernen")
                        }
                    }
                }
            }
            HStack {
                Button(copied ? "Kopiert ✓" : "Diagnose kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.stream.diagnosisReport, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                Button("Protokoll leeren") { StreamLog.shared.clear() }
            }
        } header: {
            Text("Teradek-Netzwerkstream")
        } footer: {
            Text("Für Encoder mit RTSP-, MPEG-TS- oder HLS-Ausgang (Cube, Bond, Prism …). H.264/HEVC und AAC werden direkt empfangen und dekodiert; reißt die Verbindung ab, verbindet Kuhtake sich alle paar Sekunden neu. "
                 + "„Diagnose kopieren“ legt das komplette Protokoll (RTSP-Austausch, Pakete, Decoder) in die Zwischenablage.\n" + streamAddressHelp)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct VuerSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var browser = TeradekBrowser.shared

    var body: some View {
        Section {
            let app = VuerApp.hdr
            let active = settings.source?.kind == .vuer
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(active ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    Text(!app.isInstalled ? "nicht installiert" : app.isRunning ? "läuft" : "installiert, nicht gestartet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !app.isRunning {
                    Button(app.isInstalled ? "Starten" : "Im App Store") { app.launch() }
                }
                if active {
                    Text("Aktiv").foregroundStyle(.secondary)
                } else {
                    Button("Verwenden") { AppController.shared.select(source: .vuer(app)) }
                }
            }
            ForEach(browser.encoders) { e in
                LabeledContent(e.name) {
                    HStack {
                        Text(e.host.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? "…").foregroundStyle(.secondary)
                        if let url = e.webURL { Link("Web-UI", destination: url) }
                    }
                }
            }
        } header: {
            Text("Teradek Serv Pro / VUER")
        } footer: {
            Text("Serv Pro & Co. senden über Teradeks eigenes Protokoll an die VUER-App. Kuhtake nimmt das dekodierte Bild aus dem Vuer-HDR-Fenster in voller Auflösung auf – auch wenn es verdeckt ist – und findet das Fenster nach einem Neustart von Vuer selbst wieder. Im Netzwerk gefundene Teradek-Encoder stehen oben.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { browser.start() }
    }
}

// MARK: - Timecode

private struct TimecodeSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var reader = AppController.shared.timecode

    var body: some View {
        Form {
            Section {
                Toggle("Timecode aus dem Bild lesen", isOn: $settings.timecodeEnabled)
                LabeledContent("Bereich") {
                    Button("Im Live-Bild festlegen …") { TimecodeWindow.show() }
                }
                LabeledContent("Aktuell") {
                    HStack(spacing: 8) {
                        TimecodeText(size: 15)
                        Text(reader.isLocked ? "erkannt" : "nicht erkannt").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Kuhtake liest den Timecode, den die Kamera ins Bild einblendet (z. B. das SDI-Overlay einer ARRI Alexa 35), und schreibt ihn als Start-Timecode in jede neue Datei. Ohne erkannten Timecode steht er auf 00:00:00:00.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Timecode-Basis", value: "\(reader.quanta) Bilder/s")
                if !settings.codec.isProRes, settings.container == .mp4 {
                    Label("MPEG-4 (.mp4) kann keine Timecode-Spur enthalten – für Timecode QuickTime (.mov) wählen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Die Basis folgt der Aufnahme-Bildrate (23,976 → 24, 29,97 → 30). In .mov-Dateien wird eine QuickTime-Timecode-Spur geschrieben, die Resolve, Premiere, Avid und Final Cut übernehmen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}

// MARK: - Benennung

private struct NamingSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var template = AppSettings.shared.namingTemplate

    var body: some View {
        Form {
            Section {
                Toggle("Benennung nach jedem Clip abfragen", isOn: $settings.showNamingPrompt)
            } footer: {
                Text("Ist die Abfrage aus, zählt der Take automatisch weiter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                labelField("Szene", text: $settings.sceneLabel, example: "12A")
                labelField("Shot", text: $settings.shotLabel, example: "03")
                labelField("Take", text: $settings.takeLabel, example: "07")
                LabeledContent("Beispiel") {
                    Text(ClipNaming.previewPath(for: ClipName(scene: "12A", shot: 3, take: 7)))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Bezeichnungen")
            } footer: {
                Text("Steht vor der Szene, dem Shot und dem Take im Ordner- und Dateinamen. Der File Browser findet und sortiert alle Clips, die diese Bezeichnungen tragen – jeweils gefolgt von einer ein- bis dreistelligen Zahl (z. B. SH3, SH03, SH003). Leer lassen für reine Zahlen. Den nächsten Clip stellst du im Hauptfenster oben rechts ein.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Namensschema") {
                NamingSchemeEditor(template: $template, example: ClipNaming.next)
                    .onChange(of: template) { _, t in
                        // Applied as soon as it's valid; the source browser re-indexes right away.
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if NamingScheme.validate(trimmed) == nil, trimmed != settings.namingTemplate {
                            settings.namingTemplate = trimmed
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onReceive(settings.$namingTemplate) { t in
            if NamingScheme.validate(template) == nil || t == template { template = t }
        }
    }

    private func labelField(_ title: String, text: Binding<String>, example: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: Binding(get: { text.wrappedValue },
                                               set: { text.wrappedValue = NamingScheme.Labels.clean($0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .labelsHidden()
                    .frame(width: 90)
                Text("→ \(text.wrappedValue)\(example)")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
            }
        }
    }
}

// MARK: - Tastenkürzel

private struct ShortcutSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    var body: some View {
        Form {
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        row(action)
                    }
                }
            }
            Section {
                LabeledContent("Einstellungen") { Text("⌘,").foregroundStyle(.secondary) }
                LabeledContent("Take in Monitor 1 / 2 laden") { Text("1  /  2").foregroundStyle(.secondary) }
                LabeledContent("Beide Monitore abspielen / anhalten") { Text("Leertaste").foregroundStyle(.secondary) }
                LabeledContent("Aufnahme über das Menüleisten-Symbol") { Text("⌘-Klick").foregroundStyle(.secondary) }
            } header: {
                Text("Feste Tasten")
            } footer: {
                HStack {
                    Text("„Systemweit“: wirkt auch, wenn eine andere App im Vordergrund ist. Sonst nur in Kuhtake-Fenstern.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Standard wiederherstellen") { settings.resetShortcuts() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
    }

    private func row(_ action: ShortcutAction) -> some View {
        let binding = settings.shortcut(for: action)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: action.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if hotKeys.conflicts.contains(action) {
                    Label("Von einer anderen App belegt", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if action.allowsGlobal {
                Toggle("Systemweit", isOn: Binding(get: { binding.global }, set: { settings.setGlobal($0, for: action) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Auch auslösen, wenn eine andere App im Vordergrund ist")
            } else {
                Text("nur in Kuhtake").font(.caption).foregroundStyle(.tertiary)
            }
            ShortcutRecorder(action: action)
        }
    }
}
