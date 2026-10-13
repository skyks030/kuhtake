import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.rebuild()
        statusMenu = StatusMenuController()
        HotKeyCenter.shared.start()
        _ = DeckLinkDirectory.shared   // starts device discovery
        ClipIndex.shared.start()

        AppController.shared.startup()
        PreviewWindow.show()

        let source = AppSettings.shared.source
        if source?.needsScreenCapturePermission == true, !CGPreflightScreenCaptureAccess() {
            PermissionsWindow.show()
        } else if source == nil {
            // DeckLink devices are reported shortly after discovery starts – only ask if there's nothing to pick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard AppSettings.shared.source == nil else { return }
                if let only = DeckLinkDirectory.shared.devices.first, DeckLinkDirectory.shared.devices.count == 1 {
                    AppController.shared.select(source: .deckLink(only))
                } else {
                    SourcePickerWindow.show()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Updater.shared.check(userInitiated: false)
        }
    }

    /// Dock icon clicked (while a window is open) – bring the preview back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreviewWindow.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppController.shared.isRecording else { return .terminateNow }
        AppController.shared.stopRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
