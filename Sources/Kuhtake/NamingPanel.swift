import AppKit
import SwiftUI

/// Shows the scene/shot/take dialog after each clip (queued if several clips finish in a row).
final class NamingPanelController {
    static let shared = NamingPanelController()

    private var queue: [Recorder.Result] = []
    private var panel: NSPanel?

    func enqueue(clip: Recorder.Result) {
        queue.append(clip)
        if panel == nil { showNext() }
    }

    /// Lets the user set the counter for the next clip without a recording.
    func editNext() {
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        present(title: "Nächsten Clip benennen", info: "Gilt für die nächste Aufnahme. Shot und Take zählen danach automatisch weiter.",
                saveLabel: "Übernehmen", discard: nil) { name in
            ClipNaming.setNext(name)
        }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let clip = queue.removeFirst()
        let duration = Self.format(duration: clip.duration)
        let pending = queue.count
        let info = "Clip fertig (\(duration))" + (pending > 0 ? " · \(pending) weitere(r) warten" : "")
        present(title: "Clip benennen", info: info, saveLabel: "Speichern",
                discard: { AppController.shared.discard(clip: clip.url) }) { name in
            AppController.shared.save(clip: clip.url, as: name)
        }
    }

    private func present(title: String, info: String, saveLabel: String, discard: (() -> Void)?, save: @escaping (ClipName) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let finish: () -> Void = { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            DispatchQueue.main.async { self?.showNext() }
        }
        let view = NamingView(initial: ClipNaming.next, info: info, saveLabel: saveLabel,
                              onSave: { name in save(name); finish() },
                              onDiscard: discard.map { d in { d(); finish() } })
        panel.contentViewController = NSHostingController(rootView: view)
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func format(duration: TimeInterval) -> String {
        let t = Int(duration.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct NamingView: View {
    let initial: ClipName
    let info: String
    let saveLabel: String
    let onSave: (ClipName) -> Void
    let onDiscard: (() -> Void)?

    @State private var scene: String
    @State private var shot: Int
    @State private var take: Int
    @State private var confirmDiscard = false
    @FocusState private var sceneFocused: Bool

    init(initial: ClipName, info: String, saveLabel: String, onSave: @escaping (ClipName) -> Void, onDiscard: (() -> Void)?) {
        self.initial = initial
        self.info = info
        self.saveLabel = saveLabel
        self.onSave = onSave
        self.onDiscard = onDiscard
        _scene = State(initialValue: initial.scene)
        _shot = State(initialValue: initial.shot)
        _take = State(initialValue: initial.take)
    }

    private var name: ClipName { ClipName(scene: scene.trimmingCharacters(in: .whitespaces), shot: shot, take: take) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: CowArt.illustration(size: 36))
                Text(info).font(.callout).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Szene").gridColumnAlignment(.trailing)
                    TextField("z. B. 12A", text: $scene)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .focused($sceneFocused)
                        .onChange(of: scene) { _, new in
                            if new != initial.scene { take = 1 }
                        }
                }
                GridRow {
                    Text("Shot")
                    TwoDigitField(value: $shot)
                        .onChange(of: shot) { _, _ in take = 1 }
                }
                GridRow {
                    Text("Take")
                    TwoDigitField(value: $take)
                }
            }

            HStack {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text("\(name.sceneFolderName)/\(name.baseFileName).\(AppSettings.shared.effectiveContainer.fileExtension)")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack {
                if let onDiscard {
                    Button("Verwerfen", role: .destructive) { confirmDiscard = true }
                        .confirmationDialog("Clip wirklich löschen?", isPresented: $confirmDiscard) {
                            Button("Löschen", role: .destructive, action: onDiscard)
                        }
                }
                Spacer()
                Button(saveLabel) { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.scene.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { sceneFocused = true }
    }
}

/// Two-digit number with stepper (01–99).
private struct TwoDigitField: View {
    @Binding var value: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("01", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 52)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
                .onChange(of: text) { _, t in
                    let digits = String(t.filter(\.isNumber).prefix(2))
                    if digits != t { text = digits }
                    if let n = Int(digits), n > 0, n != value { value = n }
                }
            Stepper("", value: $value, in: 1...99).labelsHidden()
        }
        .onAppear { text = ClipName.twoDigits(value) }
        .onChange(of: value) { _, v in
            if Int(text) != v { text = ClipName.twoDigits(v) }
        }
    }

    private func commit() {
        text = ClipName.twoDigits(value)
    }
}
