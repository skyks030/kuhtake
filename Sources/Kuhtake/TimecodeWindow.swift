import AppKit
import SwiftUI

enum TimecodeWindow {
    static func show() {
        WindowPresenter.shared.show(id: "timecode", title: "Timecode-Bereich festlegen", size: CGSize(width: 900, height: 700), resizable: true) {
            TimecodeSetupView()
        }
    }
}

/// Top of the live view: the current timecode, where it comes from, and the way into the setup.
struct TimecodeBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var reader = AppController.shared.timecode

    var body: some View {
        HStack(spacing: 10) {
            Text("TC").font(.caption.weight(.heavy)).foregroundStyle(.secondary)
            TimecodeText(size: 22)
                .foregroundStyle(reader.isLocked ? Color.primary : Color.secondary)
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                TimecodeWindow.show()
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Timecode-Bereich im Bild festlegen")
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var statusColor: Color {
        !settings.timecodeEnabled ? .gray : reader.isLocked ? .green : .orange
    }

    private var statusText: String {
        if !settings.timecodeEnabled { return "Timecode-Erkennung aus" }
        return reader.isLocked ? "aus dem Bild gelesen" : "kein Timecode erkannt"
    }
}

/// HH:MM:SS:FF, running at the frame rate (00:00:00:00 without a recognised timecode).
struct TimecodeText: View {
    let size: CGFloat
    @ObservedObject private var reader = AppController.shared.timecode

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Text(TimecodeReader.format(frames: reader.currentFrames() ?? 0, quanta: reader.quanta))
                .font(.system(size: size, weight: .semibold, design: .monospaced))
        }
    }
}

struct TimecodeSetupView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var reader = AppController.shared.timecode
    @StateObject private var preview = LivePreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if controller.captureState == .running {
                    RegionEditor(image: preview.image, region: $settings.timecodeRegion, shape: .rectangle,
                                 highlight: reader.isLocked, activeColor: .green) {}
                } else {
                    VStack(spacing: 8) {
                        Image(nsImage: CowArt.illustration(size: 96)).opacity(0.9)
                        Text("Keine aktive Quelle – der Bereich wird im Live-Bild festgelegt.")
                        Menu("Quelle wählen") { SourceMenuItems() }.fixedSize()
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .frame(minHeight: 360)

            Form {
                Section {
                    Toggle("Timecode aus dem Bild lesen", isOn: $settings.timecodeEnabled)
                    LabeledContent("Timecode") {
                        HStack(spacing: 8) {
                            TimecodeText(size: 17)
                            Circle().fill(reader.isLocked ? Color.green : .orange).frame(width: 8, height: 8)
                            Text(reader.isLocked ? "erkannt" : "nicht erkannt").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Gelesener Text") {
                        Text(reader.lastText ?? "–")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } footer: {
                    Text("Ziehe den Rahmen genau über die Timecode-Anzeige der Kamera (z. B. das TC-Feld im SDI-Overlay einer ARRI Alexa 35). Kuhtake liest den Timecode mehrmals pro Sekunde, lässt ihn dazwischen bildgenau weiterlaufen und schreibt ihn als Start-Timecode in jede neue Datei. Wird kein Timecode erkannt, steht er auf 00:00:00:00.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Timecode-Basis", value: "\(reader.quanta) Bilder/s (aus der Aufnahme-Bildrate \(settings.frameRate.label))")
                    if !settings.codec.isProRes, settings.container == .mp4 {
                        Label("MPEG-4-Dateien (.mp4) können keine Timecode-Spur enthalten – für Timecode in den Dateien QuickTime (.mov) wählen.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("In .mov-Dateien landet der Timecode als QuickTime-Timecode-Spur – Resolve, Premiere, Avid und Final Cut übernehmen ihn als Start-Timecode des Clips. Gelesen wird Non-Drop-Frame.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 330)
        }
        .frame(minWidth: 640, minHeight: 640)
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
    }
}

// MARK: - Picture area of window / screen sources

enum CropWindow {
    static func show() {
        WindowPresenter.shared.show(id: "crop", title: "Bildausschnitt festlegen", size: CGSize(width: 900, height: 680), resizable: true,
                                   onClose: { AppController.shared.setCropEditing(false) }) {
            CropEditorView()
        }
    }
}

/// Cuts the video area out of a captured window (e.g. VUER's toolbars) – everything else works on this part only.
struct CropEditorView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared
    @StateObject private var preview = LivePreviewModel()
    @State private var draft = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var detectionFailed = false

    private static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if controller.captureState == .running, settings.source?.isScreenCapture == true {
                    RegionEditor(image: preview.image, region: $draft, shape: .rectangle, highlight: false) {}
                } else {
                    Text(settings.source?.isScreenCapture == false
                         ? "Ein Bildausschnitt lässt sich nur für Fenster, Bildschirme und VUER festlegen."
                         : "Keine aktive Quelle.")
                        .foregroundStyle(.white)
                }
            }
            .frame(minHeight: 380)

            VStack(alignment: .leading, spacing: 10) {
                Text("Ziehe den Rahmen um das eigentliche Videobild. Aufnahme, Vorschau, Auto-Aufnahme und Timecode-Erkennung verwenden danach nur diesen Ausschnitt – in voller Auflösung.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if detectionFailed {
                    Label("Kein eindeutiger Videobereich gefunden – bitte von Hand aufziehen.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button {
                        if let pb = controller.hub.latestPixelBuffer, let area = VideoAreaDetector.detect(in: pb) {
                            draft = area
                            detectionFailed = false
                        } else {
                            detectionFailed = true
                        }
                    } label: {
                        Label("Automatisch erkennen", systemImage: "viewfinder")
                    }
                    Button("Ganzes Bild") { draft = Self.full }
                    Spacer()
                    Text(String(format: "%.0f × %.0f %%", draft.width * 100, draft.height * 100))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Abbrechen") { WindowPresenter.shared.close(id: "crop") }
                        .keyboardShortcut(.cancelAction)
                    Button("Übernehmen") {
                        let isFull = draft.width > 0.995 && draft.height > 0.995
                        controller.setCrop(isFull ? nil : draft)
                        WindowPresenter.shared.close(id: "crop")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.source?.isScreenCapture != true)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            draft = settings.source?.crop ?? Self.full
            controller.setCropEditing(true)
            preview.start()
        }
        .onDisappear {
            controller.setCropEditing(false)
            preview.stop()
        }
    }
}
