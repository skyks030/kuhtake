import AppKit
import CoreImage
import SwiftUI

enum AutoRecordWindow {
    static func show() {
        WindowPresenter.shared.show(id: "auto", title: "Auto-Aufnahme einrichten", size: CGSize(width: 900, height: 720), resizable: true,
                                   onClose: { AppController.shared.autoTriggerSuspended = false }) {
            AutoRecordView()
        }
    }
}

/// Polls the latest captured frame for the live preview.
@MainActor
final class LivePreviewModel: ObservableObject {
    @Published var image: CGImage?
    private var timer: Timer?
    private let ci = CIContext(options: [.cacheIntermediates: false])

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let pb = AppController.shared.engine.latestPixelBuffer else { return }
        var img = CIImage(cvPixelBuffer: pb)
        let maxWidth: CGFloat = 1280
        if img.extent.width > maxWidth {
            let s = maxWidth / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        image = ci.createCGImage(img, from: img.extent)
    }
}

struct AutoRecordView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var detector = AppController.shared.detector
    @StateObject private var preview = LivePreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if controller.captureState == .running {
                    RegionEditor(image: preview.image, region: $settings.region, shape: settings.regionShape,
                                 highlight: detector.isActive) {
                        detector.captureBaseline()
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(nsImage: CowArt.illustration(size: 96)).opacity(0.9)
                        Text("Keine aktive Quelle. Bitte zuerst über „Quelle wählen …“ ein Fenster oder einen Bildschirm auswählen.")
                            .multilineTextAlignment(.center)
                        Button("Quelle wählen …") { SourcePickerWindow.show() }
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .frame(minHeight: 360)

            Form {
                Section {
                    Toggle("Auto-Aufnahme aktiv", isOn: Binding(
                        get: { settings.autoRecordEnabled },
                        set: { controller.setAutoRecord($0) }))
                    Picker("Form des Bereichs", selection: $settings.regionShape) {
                        ForEach(RegionShape.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.regionShape) { _, _ in detector.captureBaseline() }
                } footer: {
                    Text("Ziehe den Bereich z. B. über die REC-Anzeige der Kamera. Wenn sich die Pixel dort deutlich vom Ruhezustand unterscheiden, startet die Aufnahme – kehrt der Bereich in den Ruhezustand zurück, stoppt sie. Ziehen auf freier Fläche zeichnet einen neuen Bereich.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Empfindlichkeit") {
                        HStack {
                            Text("gering").font(.caption)
                            Slider(value: $settings.sensitivity, in: 0...1)
                            Text("hoch").font(.caption)
                        }
                    }
                    ChangeMeter(score: detector.score, threshold: detector.currentThreshold, active: detector.isActive)
                    LabeledContent("Start-Verzögerung") {
                        HStack {
                            Slider(value: rounded($settings.startDelay), in: 0...3)
                            Text(String(format: "%.1f s", settings.startDelay)).monospacedDigit().frame(width: 44)
                        }
                    }
                    LabeledContent("Stopp-Verzögerung") {
                        HStack {
                            Slider(value: rounded($settings.stopDelay), in: 0...10)
                            Text(String(format: "%.1f s", settings.stopDelay)).monospacedDigit().frame(width: 44)
                        }
                    }
                    HStack {
                        Button {
                            detector.captureBaseline()
                        } label: {
                            Label("Aktuelles Bild als Ruhezustand übernehmen", systemImage: "camera.metering.center.weighted")
                        }
                        Spacer()
                        Text(settings.baseline == nil ? "Kein Ruhezustand gespeichert" : "Ruhezustand gespeichert")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Den Ruhezustand übernehmen, während die Kamera NICHT aufnimmt. Eine Stopp-Verzögerung von 1–2 s überbrückt blinkende REC-Anzeigen. Solange dieses Fenster offen ist, wird nicht automatisch aufgenommen – die Anzeige zeigt nur, ob ausgelöst würde.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 380)
        }
        .frame(minWidth: 640, minHeight: 640)
        .onAppear {
            controller.autoTriggerSuspended = true
            preview.start()
        }
        .onDisappear {
            controller.autoTriggerSuspended = false
            preview.stop()
        }
    }

    /// Continuous slider (no tick marks) that stores tenths of a second.
    private func rounded(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = ($0 * 10).rounded() / 10 })
    }
}

private struct ChangeMeter: View {
    let score: Double
    let threshold: Double
    let active: Bool

    var body: some View {
        LabeledContent("Veränderung") {
            HStack {
                // Scaled to the threshold: the marker in the middle is the trigger point.
                GeometryReader { geo in
                    let level = threshold > 0 ? min(score / threshold, 2) / 2 : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.2))
                        Capsule().fill(score >= threshold ? Color.red : Color.green)
                            .frame(width: max(4, geo.size.width * level))
                        Rectangle().fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: geo.size.width / 2 - 1)
                    }
                }
                .frame(height: 10)
                Text(active ? "AUSGELÖST" : "Ruhe")
                    .font(.caption.bold())
                    .foregroundStyle(active ? .red : .secondary)
                    .frame(width: 72)
            }
        }
    }
}

/// Live preview with a draggable / resizable detection region.
struct RegionEditor: View {
    let image: CGImage?
    @Binding var region: CGRect
    let shape: RegionShape
    let highlight: Bool
    let onCommit: () -> Void

    @State private var dragStart: CGRect?

    private enum Handle: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let imgSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 16, height: 9)
            let fit = Self.aspectFit(imgSize, in: geo.size)
            let r = CGRect(x: fit.minX + region.minX * fit.width, y: fit.minY + region.minY * fit.height,
                           width: region.width * fit.width, height: region.height * fit.height)
            let color: Color = highlight ? .red : .yellow

            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                }
                // Drawing a new region on empty area.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                    .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                        let a = normalize(v.startLocation, fit), b = normalize(v.location, fit)
                        region = clamp(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                    }.onEnded { _ in onCommit() })

                Group {
                    if shape == .ellipse {
                        Ellipse().fill(color.opacity(0.18)).overlay(Ellipse().stroke(color, lineWidth: 2))
                    } else {
                        Rectangle().fill(color.opacity(0.18)).overlay(Rectangle().stroke(color, lineWidth: 2))
                    }
                }
                .overlay(Rectangle().stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .gesture(DragGesture().onChanged { v in
                    let start = dragStart ?? region
                    dragStart = start
                    var n = start
                    n.origin.x = min(max(0, start.minX + v.translation.width / fit.width), 1 - start.width)
                    n.origin.y = min(max(0, start.minY + v.translation.height / fit.height), 1 - start.height)
                    region = n
                }.onEnded { _ in dragStart = nil; onCommit() })

                ForEach(Handle.allCases, id: \.self) { h in
                    let p = point(for: h, in: r)
                    Circle().fill(Color.white).overlay(Circle().stroke(color, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(p)
                        .gesture(DragGesture().onChanged { v in
                            let start = dragStart ?? region
                            dragStart = start
                            region = resize(start, handle: h, dx: v.translation.width / fit.width, dy: v.translation.height / fit.height)
                        }.onEnded { _ in dragStart = nil; onCommit() })
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func normalize(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: min(max(0, (p.x - fit.minX) / fit.width), 1), y: min(max(0, (p.y - fit.minY) / fit.height), 1))
    }

    private func clamp(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.01
        var r = r
        r.size.width = max(minSize, min(r.width, 1))
        r.size.height = max(minSize, min(r.height, 1))
        r.origin.x = min(max(0, r.minX), 1 - r.width)
        r.origin.y = min(max(0, r.minY), 1 - r.height)
        return r
    }

    private func point(for h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func resize(_ s: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }
        minX = max(0, minX); minY = max(0, minY); maxX = min(1, maxX); maxY = min(1, maxY)
        return clamp(CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)))
    }
}
