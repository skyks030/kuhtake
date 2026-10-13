import AppKit
import ScreenCaptureKit
import SwiftUI

enum SourcePickerWindow {
    static func show() {
        WindowPresenter.shared.show(id: "source", title: "Quelle wählen", size: CGSize(width: 820, height: 600), resizable: true) {
            SourcePickerView()
        }
    }
}

struct SourceCandidate: Identifiable {
    let id: String
    let source: CaptureSource
    let title: String
    let subtitle: String
    let icon: NSImage?
    let filter: SCContentFilter
    let aspect: CGFloat
    var thumbnail: CGImage?
}

@MainActor
final class SourcePickerModel: ObservableObject {
    @Published var displays: [SourceCandidate] = []
    @Published var windows: [SourceCandidate] = []
    @Published var loading = false
    @Published var error: String?

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownBundle = Bundle.main.bundleIdentifier

            displays = content.displays.map { d in
                let name = DisplayNames.name(for: d.displayID)
                let source = CaptureSource(kind: .display, displayID: d.displayID, label: "Bildschirm: \(name)")
                return SourceCandidate(id: "d\(d.displayID)", source: source, title: name,
                                       subtitle: "Gesamter Bildschirm · \(d.width)×\(d.height) pt",
                                       icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil),
                                       filter: SCContentFilter(display: d, excludingWindows: []),
                                       aspect: CGFloat(d.width) / CGFloat(max(d.height, 1)))
            }

            windows = content.windows
                .filter { w in
                    w.windowLayer == 0 && w.frame.width > 120 && w.frame.height > 80
                        && w.owningApplication != nil && w.owningApplication?.bundleIdentifier != ownBundle
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                .map { w in
                    let app = w.owningApplication
                    let appName = app?.applicationName ?? "Unbekannt"
                    let title = (w.title?.isEmpty == false) ? w.title! : appName
                    let source = CaptureSource(kind: .window, windowID: w.windowID, appBundleID: app?.bundleIdentifier,
                                               appName: appName, windowTitle: w.title, label: "\(appName) – \(title)")
                    let icon = app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
                    return SourceCandidate(id: "w\(w.windowID)", source: source, title: title,
                                           subtitle: "\(appName) · \(Int(w.frame.width))×\(Int(w.frame.height))",
                                           icon: icon, filter: SCContentFilter(desktopIndependentWindow: w),
                                           aspect: w.frame.width / max(w.frame.height, 1))
                }
            await loadThumbnails()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadThumbnails() async {
        for i in displays.indices { displays[i].thumbnail = await Self.thumbnail(displays[i]) }
        for i in windows.indices { windows[i].thumbnail = await Self.thumbnail(windows[i]) }
    }

    private static func thumbnail(_ c: SourceCandidate) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        cfg.width = 480
        cfg.height = max(2, Int(480 / max(c.aspect, 0.1)))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: c.filter, configuration: cfg)
    }
}

struct SourcePickerView: View {
    @StateObject private var model = SourcePickerModel()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var directory = DeckLinkDirectory.shared
    private let hasScreenPermission = CGPreflightScreenCaptureAccess()
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Welche Quelle soll aufgenommen werden?")
                    .font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    deckLinkSection
                    VuerPickerSection(columns: columns)
                    if !hasScreenPermission {
                        HStack {
                            Label("Für Bildschirme und Fenster braucht Kuhtake die Bildschirmaufnahme-Berechtigung.", systemImage: "lock.shield")
                            Spacer()
                            Button("Einrichten …") { PermissionsWindow.show() }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
                    }
                    if let error = model.error, hasScreenPermission {
                        Text(error).foregroundStyle(.red)
                    }
                    section("Bildschirme", model.displays)
                    section("Fenster", model.windows)
                }
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .task { if hasScreenPermission { await model.load() } }
    }

    @ViewBuilder
    private var deckLinkSection: some View {
        Text("Blackmagic DeckLink / UltraStudio").font(.title3.bold())
        if !directory.driverAvailable {
            Text("Blackmagic Desktop Video ist nicht installiert – ohne den Treiber sind keine Hardware-Eingänge verfügbar.")
                .foregroundStyle(.secondary)
        } else if directory.devices.isEmpty {
            Text("Kein Gerät angeschlossen. Sobald eins angesteckt wird, erscheint es hier.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(directory.devices) { d in
                    DeckLinkTile(device: d, selected: settings.source?.kind == .decklink && settings.source?.deckLinkID == d.id) {
                        AppController.shared.select(source: .deckLink(d))
                        WindowPresenter.shared.close(id: "source")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SourceCandidate]) -> some View {
        if !items.isEmpty {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(items) { c in
                    SourceTile(candidate: c, selected: isSelected(c)) {
                        AppController.shared.select(source: c.source)
                        WindowPresenter.shared.close(id: "source")
                    }
                }
            }
        }
    }

    private func isSelected(_ c: SourceCandidate) -> Bool {
        settings.source?.isSame(as: c.source) ?? false
    }
}

private struct DeckLinkTile: View {
    let device: DeckLinkDevice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                    if selected {
                        LiveVideoView().clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(height: 140)
                HStack(spacing: 8) {
                    Image(systemName: "video.fill").frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text("Hardware-Eingang · DeckLink SDK").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SourceTile: View {
    let candidate: SourceCandidate
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                    if let t = candidate.thumbnail {
                        Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    if let icon = candidate.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(candidate.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Teradek: the VUER app window as a source, plus the encoders VUER would see on the network.
private struct VuerPickerSection: View {
    let columns: [GridItem]
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var browser = TeradekBrowser.shared
    @State private var hovering = false

    var body: some View {
        let app = VuerApp.hdr
        let selected = settings.source?.kind == .vuer
        Text("Teradek Serv Pro / VUER").font(.title3.bold())
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            Button {
                AppController.shared.select(source: .vuer(app))
                if !app.isRunning { app.launch() }
                WindowPresenter.shared.close(id: "source")
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                        if selected {
                            LiveVideoView().clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 38, weight: .light))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(height: 140)
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill").frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(!app.isInstalled ? "Nicht installiert – öffnet den App Store" : app.isRunning ? "App-Fenster · Videobereich automatisch" : "Wird beim Auswählen gestartet")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        HStack(spacing: 6) {
            if browser.encoders.isEmpty {
                if browser.isSearching { ProgressView().controlSize(.mini) }
                Text("Kein Teradek-Encoder im Netzwerk gefunden – Serv Pro und Mac müssen im selben Netz sein.")
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                Text("Im Netzwerk: " + browser.encoders.map { e in
                    e.host.map { "\(e.name) (\($0.hasSuffix(".") ? String($0.dropLast()) : $0))" } ?? e.name
                }.joined(separator: ", "))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .onAppear { browser.start() }
    }
}
