import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer version and installs it in place.
final class Updater {
    static let shared = Updater()

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "KuhtakeGitHubRepo") as? String ?? "skyks030/kuhtake"
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        let tag_name: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private var checking = false

    // MARK: Check

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Kuhtake/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    if userInitiated { await info("Es wurde noch keine Version veröffentlicht.") }
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = Self.normalize(release.tag_name)
                guard Self.compare(latest, Self.currentVersion) == .orderedDescending else {
                    if userInitiated { await info("Kuhtake ist aktuell (Version \(Self.currentVersion)).") }
                    return
                }
                if !userInitiated, AppSettings.shared.skippedVersion == latest { return }
                guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
                    if userInitiated { await info("Version \(latest) enthält kein installierbares Paket.") }
                    return
                }
                await offer(version: latest, notes: release.body ?? "", asset: asset)
            } catch {
                if userInitiated { await info("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)") }
            }
        }
    }

    @MainActor
    private func info(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Software-Update"
        alert.informativeText = text
        alert.runModal()
    }

    @MainActor
    private func offer(version: String, notes: String, asset: Release.Asset) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kuhtake \(version) ist verfügbar"
        var text = "Installiert ist Version \(Self.currentVersion)."
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += "\n\n" + String(trimmed.prefix(800)) }
        alert.informativeText = text
        alert.addButton(withTitle: "Jetzt installieren")
        alert.addButton(withTitle: "Später")
        alert.addButton(withTitle: "Diese Version ignorieren")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if AppController.shared.isRecording {
                info("Bitte zuerst die laufende Aufnahme beenden und dann erneut nach Updates suchen.")
                return
            }
            install(asset: asset, version: version)
        case .alertThirdButtonReturn:
            AppSettings.shared.skippedVersion = version
        default:
            break
        }
    }

    // MARK: Install

    @MainActor
    private func install(asset: Release.Asset, version: String) {
        let progress = UpdateProgress()
        WindowPresenter.shared.show(id: "update", title: "Update wird installiert", size: CGSize(width: 380, height: 120)) {
            UpdateProgressView(progress: progress)
        }
        Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("kuhtake-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

                await MainActor.run { progress.status = "Lade Version \(version) …" }
                let zip = work.appendingPathComponent(asset.name)
                try await download(asset.browser_download_url, to: zip, expectedSize: asset.size, progress: progress)

                await MainActor.run { progress.status = "Entpacke …"; progress.fraction = nil }
                let unpacked = work.appendingPathComponent("unpacked")
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

                guard let newApp = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "Kuhtake", code: 1, userInfo: [NSLocalizedDescriptionKey: "Im Paket wurde keine App gefunden."])
                }
                let newBundle = Bundle(url: newApp)
                guard newBundle?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw NSError(domain: "Kuhtake", code: 2, userInfo: [NSLocalizedDescriptionKey: "Das Paket enthält eine fremde App."])
                }
                try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

                await MainActor.run { progress.status = "Installiere und starte neu …" }
                try replaceAndRelaunch(with: newApp)
            } catch {
                await MainActor.run {
                    WindowPresenter.shared.close(id: "update")
                    self.info("Update fehlgeschlagen: \(error.localizedDescription)")
                }
            }
        }
    }

    private func download(_ url: URL, to dest: URL, expectedSize: Int, progress: UpdateProgress) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Kuhtake", code: 3, userInfo: [NSLocalizedDescriptionKey: "Download fehlgeschlagen."])
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        let total = max(expectedSize, Int(response.expectedContentLength), 1)
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                let f = Double(written) / Double(total)
                await MainActor.run { progress.fraction = f }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    /// Hands off to a small shell script that swaps the bundle once this process has exited, then launches the new one.
    private func replaceAndRelaunch(with newApp: URL) throws {
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then
          rm -rf "$DEST.old"
        else
          rm -rf "$DEST"; mv "$DEST.old" "$DEST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        let parentWritable = FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent)
            && FileManager.default.isWritableFile(atPath: dest)

        let task = Process()
        task.environment = ["DEST": dest, "NEW": newApp.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if parentWritable {
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script]
        } else {
            // Needs admin rights (e.g. /Applications owned by another user).
            let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("kuhtake-update.sh")
            try ("DEST=\(Self.shellQuote(dest))\nNEW=\(Self.shellQuote(newApp.path))\n" + script)
                .write(to: scriptFile, atomically: true, encoding: .utf8)
            let apple = "do shell script \"/bin/sh \(scriptFile.path) > /dev/null 2>&1 &\" with administrator privileges"
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", apple]
        }
        try task.run()
        if !parentWritable {
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                throw NSError(domain: "Kuhtake", code: 4, userInfo: [NSLocalizedDescriptionKey: "Administrator-Berechtigung wurde nicht erteilt."])
            }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Kuhtake", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) ist fehlgeschlagen (\(p.terminationStatus))."])
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Versions

    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

final class UpdateProgress: ObservableObject {
    @Published var status = "Bereite vor …"
    @Published var fraction: Double? = 0
}

private struct UpdateProgressView: View {
    @ObservedObject var progress: UpdateProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.status)
            if let f = progress.fraction {
                ProgressView(value: f)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
