import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private var quitMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.rebuild()
        statusMenu = StatusMenuController()
        HotKeyCenter.shared.start()
        QuickSearch.installShortcut()
        // ⌘Q always quits the whole app (also from panels and while the menu bar isn't Kuhtake's) – never just a window.
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 12, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
            else { return event }
            AppController.shared.quitSafely()
            return nil
        }
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
        // A running take is finished and copies into the project folder complete before quitting.
        guard AppController.shared.hasPendingWrites else { return .terminateNow }
        AppController.shared.stopRecording()
        AppController.shared.whenWritesDone { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

// Command line: receive a network stream without the UI (see `StreamSelfTest`).
if let i = CommandLine.arguments.firstIndex(of: "--stream-selftest") {
    StreamSelfTest.run(arguments: Array(CommandLine.arguments.dropFirst(i + 1)))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
