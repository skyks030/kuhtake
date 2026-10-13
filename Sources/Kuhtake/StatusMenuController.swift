import AppKit
import Combine
import ServiceManagement

/// The menu bar icon and its dropdown menu.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller = AppController.shared
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?
    private var blinkTimer: Timer?

    override init() {
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            // ⌘-click on a status item normally starts the system's "rearrange menu bar" drag before the button
            // ever sees it, so it is caught here first: ⌘-click (and ⌥-click) on the cow toggles the recording.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let button = self.statusItem.button, event.window === button.window,
                      !event.modifierFlags.intersection([.command, .option]).isEmpty else { return event }
                self.controller.toggleRecording()
                return nil
            }
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
            button.image = CowArt.menuBarImage(recording: true)
            button.attributedTitle = NSAttributedString(string: " REC", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
            ])
            startBlink()
        } else {
            stopBlink()
            button.image = CowArt.menuBarImage(recording: false, dimmed: controller.captureState != .running)
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
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
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

        // Status (only when something needs attention)
        var status: String?
        switch controller.captureState {
        case .noSource: status = nil
        case .starting: status = "Verbinde mit Quelle …"
        case .running: status = controller.isRecording ? "● Aufnahme läuft" : nil
        case .unavailable(let why): status = "Quelle nicht verfügbar – \(why)"
        case .noPermission: status = "Bildschirmaufnahme-Berechtigung fehlt"
        }
        if let status { menu.addItem(disabled(status)) }
        if let msg = controller.lastMessage { menu.addItem(disabled(msg)) }
        if status != nil || controller.lastMessage != nil { menu.addItem(.separator()) }

        // Recording
        let noSource = settings.source == nil && !controller.isRecording
        let recTitle = controller.isRecording ? "Aufnahme stoppen" : noSource ? "Keine Input-Quelle ausgewählt" : "Aufnahme starten"
        let rec = item(recTitle, #selector(toggleRecording))
        if !noSource { MainMenu.applyShortcut(of: .toggleRecording, to: rec) }
        rec.image = NSImage(systemSymbolName: controller.isRecording ? "stop.circle" : noSource ? "video.slash" : "record.circle",
                            accessibilityDescription: nil)
        rec.isEnabled = controller.isRecording || controller.captureState == .running
        menu.addItem(rec)
        menu.addItem(.separator())

        // Preview
        menu.addItem(shortcutItem("Vorschau öffnen", .showPreview, #selector(showPreview), image: "rectangle.inset.filled"))
        menu.addItem(shortcutItem("Source Browser", .sourceBrowser, #selector(showBrowser), image: "rectangle.split.3x1"))
        menu.addItem(.separator())

        // Source
        let sourceLabel = settings.source?.label ?? "–"
        menu.addItem(disabled("Quelle: \(sourceLabel)"))
        let directory = DeckLinkDirectory.shared
        if !directory.devices.isEmpty {
            let deckLinkMenu = NSMenu()
            for d in directory.devices {
                let i = NSMenuItem(title: d.name, action: #selector(chooseDeckLink(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = d.id
                i.state = settings.source?.kind == .decklink && settings.source?.deckLinkID == d.id ? .on : .off
                deckLinkMenu.addItem(i)
            }
            let sub = item("Blackmagic-Eingang", #selector(noop), image: "cable.connector.horizontal")
            sub.submenu = deckLinkMenu
            menu.addItem(sub)
        }
        let vuer = item("Teradek Vuer HDR", #selector(chooseVuer), image: "antenna.radiowaves.left.and.right")
        vuer.state = settings.source?.kind == .vuer ? .on : .off
        menu.addItem(vuer)
        menu.addItem(shortcutItem("Fenster oder Bildschirm wählen …", .chooseSource, #selector(chooseSource), image: "macwindow.on.rectangle"))
        if settings.source?.isScreenCapture == true {
            menu.addItem(item("Bildausschnitt festlegen …", #selector(configureCrop), image: "crop"))
        }
        if case .noPermission = controller.captureState {
            menu.addItem(item("Berechtigungen einrichten …", #selector(showPermissions), image: "lock.shield"))
        }
        menu.addItem(.separator())

        // Auto recording
        menu.addItem(toggle("Auto-Aufnahme", settings.autoRecordEnabled) { [weak self] on in
            self?.controller.setAutoRecord(on)
        })
        menu.addItem(item("Auto-Aufnahme einrichten …", #selector(configureAuto), image: "viewfinder"))
        menu.addItem(.separator())

        // Timecode
        let tcFrames = controller.timecode.currentFrames()
        menu.addItem(disabled("Timecode: " + (settings.timecodeEnabled
            ? TimecodeReader.format(frames: tcFrames ?? 0, quanta: controller.timecode.quanta) + (tcFrames == nil ? " (nicht erkannt)" : "")
            : "aus")))
        menu.addItem(toggle("Timecode aus dem Bild lesen", settings.timecodeEnabled) { [weak self] on in
            self?.settings.timecodeEnabled = on
        })
        menu.addItem(item("Timecode-Bereich festlegen …", #selector(configureTimecode), image: "clock"))
        menu.addItem(.separator())

        // Naming
        menu.addItem(disabled("Nächster Clip: \(ClipNaming.nextFileName)"))
        menu.addItem(toggle("Benennung nach jedem Clip abfragen", settings.showNamingPrompt) { [weak self] on in
            self?.settings.showNamingPrompt = on
        })
        menu.addItem(shortcutItem("Szene / Shot / Take festlegen …", .nameNextClip, #selector(editNaming), image: "number"))
        menu.addItem(.separator())

        // Output
        menu.addItem(disabled("Arbeitsordner: \(abbreviate(settings.workingFolder.path))"))
        menu.addItem(item("Arbeitsordner wählen …", #selector(chooseFolder), image: "folder"))
        menu.addItem(item("Arbeitsordner im Finder zeigen", #selector(revealFolder)))
        menu.addItem(item("Dateiformat …", #selector(showFormat), image: "film"))
        menu.addItem(toggle("Ton der Quelle mit aufnehmen", settings.recordAudio) { [weak self] on in
            self?.settings.recordAudio = on
        })
        menu.addItem(.separator())

        // App
        menu.addItem(toggle("Beim Anmelden starten", SMAppService.mainApp.status == .enabled) { [weak self] on in
            self?.setLaunchAtLogin(on)
        })
        menu.addItem(item("Einstellungen …", #selector(showSettings), key: ",", image: "gearshape"))
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

    private func shortcutItem(_ title: String, _ action: ShortcutAction, _ selector: Selector, image: String? = nil) -> NSMenuItem {
        let i = item(title, selector, image: image)
        MainMenu.applyShortcut(of: action, to: i)
        return i
    }

    private func toggle(_ title: String, _ isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = MenuSwitchRow(title: title, isOn: isOn, onChange: onChange)
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
    @objc private func noop() {}
    @MainActor @objc private func showPreview() { PreviewWindow.show() }
    @MainActor @objc private func showBrowser() { PreviewWindow.show(mode: .browser) }
    @MainActor @objc private func showSettings() { SettingsWindow.show() }
    @objc private func chooseDeckLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let d = DeckLinkDirectory.shared.devices.first(where: { $0.id == id }) else { return }
        controller.select(source: .deckLink(d))
    }
    @objc private func showPermissions() { PermissionsWindow.show() }
    @objc private func configureAuto() { AutoRecordWindow.show() }
    @objc private func configureTimecode() { TimecodeWindow.show() }
    @objc private func configureCrop() { CropWindow.show() }
    @objc private func chooseVuer() { controller.select(source: .vuer()) }
    @objc private func editNaming() { NamingPanelController.shared.editNext() }
    @objc private func showFormat() { FormatWindow.show() }
    @objc private func checkUpdates() { Updater.shared.check(userInitiated: true) }
    @objc private func quit() { controller.quitSafely() }
    @objc private func chooseFolder() { WorkingFolder.choose() }

    @objc private func revealFolder() {
        try? FileManager.default.createDirectory(at: settings.workingFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.workingFolder)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if !on {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            controller.notify("Autostart konnte nicht geändert werden: \(error.localizedDescription)")
        }
    }
}

/// Menu row with a switch. Clicking it toggles without closing the menu.
private final class MenuSwitchRow: NSView {
    private let toggle = NSSwitch()
    private let label: NSTextField
    private let onChange: (Bool) -> Void

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 28))
        autoresizingMask = [.width]

        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .mini
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(switched)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 16),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func switched() {
        onChange(toggle.state == .on)
    }

    /// Clicking the label toggles too.
    override func mouseUp(with event: NSEvent) {
        toggle.state = toggle.state == .on ? .off : .on
        switched()
    }
}
