import AppKit

/// The app's menu bar menus ("Kuhtake", "Bearbeiten", "Aufnahme", "Darstellung", "Fenster").
/// Only visible while a Kuhtake window is open – see `WindowPresenter.updateActivationPolicy`.
/// Shortcuts that only work inside Kuhtake (e.g. ⌘F, ⌘R) are these menu items' key equivalents.
enum MainMenu {
    private static let target = MenuTarget()

    static func rebuild() {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(recordingMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Kuhtake")
        m.addItem(withTitle: "Über Kuhtake", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(custom("Einstellungen …", #selector(MenuTarget.showSettings), key: ","))
        m.addItem(custom("Nach Updates suchen …", #selector(MenuTarget.checkUpdates)))
        m.addItem(.separator())
        m.addItem(withTitle: "Kuhtake ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = m.addItem(withTitle: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        m.addItem(withTitle: "Alle einblenden", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(custom("Kuhtake beenden", #selector(MenuTarget.quit), key: "q"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Bearbeiten")
        m.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = m.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(.separator())
        m.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return m
    }

    private static func recordingMenu() -> NSMenu {
        let m = NSMenu(title: "Aufnahme")
        m.addItem(action(.toggleRecording))
        m.addItem(action(.startRecording))
        m.addItem(action(.stopRecording))
        m.addItem(.separator())
        m.addItem(action(.toggleAutoRecord))
        m.addItem(custom("Auto-Aufnahme einrichten …", #selector(MenuTarget.configureAuto)))
        m.addItem(custom("Timecode-Bereich festlegen …", #selector(MenuTarget.configureTimecode)))
        m.addItem(.separator())
        m.addItem(action(.chooseSource))
        m.addItem(custom("Bildausschnitt festlegen …", #selector(MenuTarget.configureCrop)))
        m.addItem(action(.nameNextClip))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "Darstellung")
        m.addItem(action(.liveView))
        m.addItem(action(.sourceBrowser))
        m.addItem(.separator())
        m.addItem(action(.showPreview))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Fenster")
        m.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        m.addItem(withTitle: "Zoomen", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        m.addItem(.separator())
        m.addItem(withTitle: "Alle nach vorne bringen", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return m
    }

    /// Menu item for a shortcut action, showing its current shortcut.
    static func action(_ a: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: a.title, action: #selector(MenuTarget.runAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = a.rawValue
        applyShortcut(of: a, to: item)
        return item
    }

    static func applyShortcut(of a: ShortcutAction, to item: NSMenuItem) {
        if let combo = AppSettings.shared.shortcut(for: a).combo {
            item.keyEquivalent = combo.menuKeyEquivalent
            item.keyEquivalentModifierMask = combo.flags
        } else {
            item.keyEquivalent = ""
        }
    }

    private static func custom(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target
        return item
    }
}

private final class MenuTarget: NSObject, NSMenuItemValidation {
    // Not `perform(_:)`: that name is NSObject's `performSelector:`, and the menu would call that instead.
    @MainActor @objc func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = ShortcutAction(rawValue: raw) else { return }
        a.perform()
    }

    @MainActor @objc func showSettings() { SettingsWindow.show() }
    @objc func checkUpdates() { Updater.shared.check(userInitiated: true) }
    @objc func configureAuto() { AutoRecordWindow.show() }
    @objc func configureTimecode() { TimecodeWindow.show() }
    @objc func configureCrop() { CropWindow.show() }
    @objc func quit() { AppController.shared.quitSafely() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(configureCrop) { return AppSettings.shared.source?.isScreenCapture == true }
        guard let raw = item.representedObject as? String, let a = ShortcutAction(rawValue: raw) else { return true }
        let c = AppController.shared
        switch a {
        case .toggleRecording:
            return c.isRecording || c.captureState == .running
        case .startRecording: return !c.isRecording && c.captureState == .running
        case .stopRecording: return c.isRecording
        case .toggleAutoRecord:
            item.state = c.settings.autoRecordEnabled ? .on : .off
            item.title = "Auto-Aufnahme"
            return true
        case .liveView:
            item.state = PreviewWindow.isVisible && PreviewModel.shared.mode == .live ? .on : .off
            return true
        case .sourceBrowser:
            item.state = PreviewWindow.isVisible && PreviewModel.shared.mode == .browser ? .on : .off
            return true
        default: return true
        }
    }
}
