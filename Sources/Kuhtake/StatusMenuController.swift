import AppKit
import Combine
import ServiceManagement

/// The menu bar icon and its dropdown menu.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller = AppController.shared
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer: Timer?

    override init() {
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
        }
        Publishers.CombineLatest3(controller.$isRecording, controller.$captureState, settings.$autoRecordEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        updateIcon()
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if controller.isRecording {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
                .applying(.init(paletteColors: [.white, .systemRed]))
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Aufnahme läuft")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.attributedTitle = NSAttributedString(string: " REC", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
            ])
            startBlink()
        } else {
            stopBlink()
            let symbol: String
            switch controller.captureState {
            case .running: symbol = "record.circle"
            case .starting: symbol = "circle.dotted"
            case .noSource, .unavailable, .noPermission: symbol = "video.slash"
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kuhtake")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString(string: settings.autoRecordEnabled ? " AUTO" : "", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            ])
        }
    }

    /// Subtle pulsing so a running recording is noticeable at a glance.
    private func startBlink() {
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            button.alphaValue = button.alphaValue < 1 ? 1 : 0.55
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        statusItem.button?.alphaValue = 1
    }

    // MARK: Click handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) || flags.contains(.option) {
            controller.toggleRecording()
            return
        }
        let menu = buildMenu()
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status
        let status: String
        switch controller.captureState {
        case .noSource: status = "Keine Quelle gewählt"
        case .starting: status = "Verbinde mit Quelle …"
        case .running: status = controller.isRecording ? "● Aufnahme läuft" : "Bereit – Vorschau aktiv"
        case .unavailable(let why): status = "Quelle nicht verfügbar – \(why)"
        case .noPermission: status = "Bildschirmaufnahme-Berechtigung fehlt"
        }
        menu.addItem(disabled(status))
        if let msg = controller.lastMessage { menu.addItem(disabled(msg)) }
        menu.addItem(.separator())

        // Recording
        let rec = item(controller.isRecording ? "Aufnahme stoppen" : "Aufnahme starten", #selector(toggleRecording), key: "r")
        rec.image = NSImage(systemSymbolName: controller.isRecording ? "stop.circle" : "record.circle", accessibilityDescription: nil)
        rec.isEnabled = controller.isRecording || controller.captureState == .running
        menu.addItem(rec)
        menu.addItem(disabled("⌘-Klick aufs Icon oder ⌃⌥⌘R startet/stoppt"))
        menu.addItem(.separator())

        // Source
        let sourceLabel = settings.source?.label ?? "–"
        menu.addItem(disabled("Quelle: \(sourceLabel)"))
        menu.addItem(item("Quelle wählen …", #selector(chooseSource), image: "macwindow.on.rectangle"))
        if case .noPermission = controller.captureState {
            menu.addItem(item("Berechtigungen einrichten …", #selector(showPermissions), image: "lock.shield"))
        }
        menu.addItem(.separator())

        // Auto recording
        let auto = item("Auto-Aufnahme aktiv", #selector(toggleAuto))
        auto.state = settings.autoRecordEnabled ? .on : .off
        menu.addItem(auto)
        menu.addItem(item("Auto-Aufnahme einrichten …", #selector(configureAuto), image: "viewfinder"))
        menu.addItem(.separator())

        // Naming
        menu.addItem(disabled("Nächster Clip: \(ClipNaming.next.baseFileName)"))
        let prompt = item("Benennung nach jedem Clip abfragen", #selector(toggleNamingPrompt))
        prompt.state = settings.showNamingPrompt ? .on : .off
        menu.addItem(prompt)
        menu.addItem(item("Szene / Shot / Take festlegen …", #selector(editNaming), image: "number"))
        menu.addItem(.separator())

        // Output
        menu.addItem(disabled("Arbeitsordner: \(abbreviate(settings.workingFolder.path))"))
        menu.addItem(item("Arbeitsordner wählen …", #selector(chooseFolder), image: "folder"))
        menu.addItem(item("Arbeitsordner im Finder zeigen", #selector(revealFolder)))
        menu.addItem(item("Dateiformat …", #selector(showFormat), image: "film"))
        let audio = item("Ton der Quelle mit aufnehmen", #selector(toggleAudio))
        audio.state = settings.recordAudio ? .on : .off
        menu.addItem(audio)
        menu.addItem(.separator())

        // App
        let login = item("Beim Anmelden starten", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Nach Updates suchen …", #selector(checkUpdates)))
        menu.addItem(disabled("Version \(Updater.currentVersion)"))
        menu.addItem(item("Kuhtake beenden", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", image: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let image { i.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Actions

    @objc private func toggleRecording() { controller.toggleRecording() }
    @objc private func chooseSource() { SourcePickerWindow.show() }
    @objc private func showPermissions() { PermissionsWindow.show() }
    @objc private func toggleAuto() { controller.setAutoRecord(!settings.autoRecordEnabled) }
    @objc private func configureAuto() { AutoRecordWindow.show() }
    @objc private func toggleNamingPrompt() { settings.showNamingPrompt.toggle() }
    @objc private func editNaming() { NamingPanelController.shared.editNext() }
    @objc private func showFormat() { FormatWindow.show() }
    @objc private func toggleAudio() { settings.recordAudio.toggle() }
    @objc private func checkUpdates() { Updater.shared.check(userInitiated: true) }
    @objc private func quit() {
        if controller.isRecording {
            controller.stopRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    @objc private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Als Arbeitsordner wählen"
        panel.directoryURL = settings.workingFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.workingFolder = url
        }
    }

    @objc private func revealFolder() {
        try? FileManager.default.createDirectory(at: settings.workingFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.workingFolder)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            controller.notify("Autostart konnte nicht geändert werden: \(error.localizedDescription)")
        }
    }
}
