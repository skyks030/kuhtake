import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController()
        hotKey = HotKey { AppController.shared.toggleRecording() }

        if CGPreflightScreenCaptureAccess() {
            AppController.shared.startup()
            if AppSettings.shared.source == nil { SourcePickerWindow.show() }
        } else {
            AppController.shared.startup()
            PermissionsWindow.show()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Updater.shared.check(userInitiated: false)
        }
    }

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
