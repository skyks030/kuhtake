import AppKit
import SwiftUI

enum PermissionsWindow {
    static func show() {
        WindowPresenter.shared.show(id: "permissions", title: "Willkommen bei Kuhtake", size: CGSize(width: 520, height: 400)) {
            PermissionsView()
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsView: View {
    @State private var granted = CGPreflightScreenCaptureAccess()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: CowArt.illustration(size: 64))
                VStack(alignment: .leading) {
                    Text("Kuhtake").font(.title.bold())
                    Text("Live-Feed abfilmen und Takes automatisch ablegen").foregroundStyle(.secondary)
                }
            }

            Text("Damit Kuhtake Fenster (z. B. den Teradek-Viewer) inkl. Ton aufnehmen kann, braucht die App die Berechtigung **Bildschirm- & Systemaudioaufnahme**.")

            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                Text(granted ? "Berechtigung erteilt" : "Berechtigung fehlt")
                    .font(.headline)
            }

            if !granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. „Berechtigung anfordern“ klicken und bestätigen.")
                    Text("2. In den Systemeinstellungen Kuhtake aktivieren.")
                    Text("3. Kuhtake neu starten (macOS verlangt das).")
                }
                .font(.callout)
                HStack {
                    Button("Berechtigung anfordern") {
                        granted = CGRequestScreenCaptureAccess()
                        if !granted { PermissionsWindow.openSystemSettings() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Systemeinstellungen öffnen") { PermissionsWindow.openSystemSettings() }
                    Spacer()
                    Button("Kuhtake neu starten") { Relauncher.relaunch() }
                }
            } else {
                Text("Alles bereit. Wähle im Menüleisten-Symbol unter „Quelle wählen …“ das Fenster, das abgefilmt werden soll.")
                    .font(.callout)
                HStack {
                    Spacer()
                    Button("Quelle wählen …") {
                        WindowPresenter.shared.close(id: "permissions")
                        AppController.shared.restartCapture()
                        SourcePickerWindow.show()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 400)
        .onReceive(timer) { _ in granted = CGPreflightScreenCaptureAccess() }
    }
}

enum Relauncher {
    /// Starts a fresh instance after this one has quit.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
    }
}
