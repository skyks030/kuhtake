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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
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
    @State private var template = AppSettings.shared.namingTemplate
    @State private var confirmDiscard = false
    @AppStorage("namingSchemeExpanded") private var schemeExpanded = false
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
    private var scheme: NamingScheme? { try? NamingScheme(template: template) }

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
                        .disabled(scheme?.hasShot == false)
                }
                GridRow {
                    Text("Take")
                    TwoDigitField(value: $take)
                }
            }

            HStack {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(scheme.map { ClipNaming.previewPath(for: name, scheme: $0) } ?? "–")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            DisclosureGroup(isExpanded: $schemeExpanded) {
                NamingSchemeEditor(template: $template, example: name)
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("Namensschema")
                    Text(template).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack {
                if let onDiscard {
                    Button("Verwerfen", role: .destructive) { confirmDiscard = true }
                        .confirmationDialog("Clip wirklich löschen?", isPresented: $confirmDiscard) {
                            Button("Löschen", role: .destructive, action: onDiscard)
                        }
                }
                Spacer()
                Button(saveLabel) {
                    if scheme != nil, template != AppSettings.shared.namingTemplate {
                        AppSettings.shared.namingTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    onSave(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.scene.isEmpty || scheme == nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { sceneFocused = true }
    }
}

/// Edits the folder / file name template. Shows what the next clip would be called and how many files in the
/// working folder the template recognises – so an existing folder structure can be described until it's found.
struct NamingSchemeEditor: View {
    @Binding var template: String
    let example: ClipName
    @ObservedObject private var settings = AppSettings.shared

    @State private var matches: Int?
    @State private var activeMatches: Int?

    private var error: NamingScheme.ParseError? { NamingScheme.validate(template) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Schema", text: $template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Menu {
                    ForEach(NamingScheme.presets) { p in
                        Button("\(p.title)   \(p.template)") { template = p.template }
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Vorlage wählen")
            }
            HStack(spacing: 6) {
                Text("Einfügen:").font(.caption).foregroundStyle(.secondary)
                tokenButton("Szene", "{szene}")
                tokenButton("Shot", "{shot}")
                tokenButton("Take", "{take}")
                tokenButton("Datum", "{datum}")
                tokenButton("Ordner /", "/")
                Spacer()
            }
            if let error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let scheme = try? NamingScheme(template: template) {
                Text("Nächster Clip: ") .font(.caption).foregroundStyle(.secondary)
                    + Text(ClipNaming.previewPath(for: example, scheme: scheme)).font(.caption.monospaced())
                matchInfo
            }
            Text("„/“ trennt Ordner, der letzte Teil ist der Dateiname. Jeder Platzhalter wird mit seiner Bezeichnung geschrieben ({szene} → \(settings.sceneLabel)12A, {shot} → \(settings.shotLabel)03, {take} → \(settings.takeLabel)07; ändern unter Einstellungen → Benennung). {take:3} schreibt den Take dreistellig. Kuhtake erkennt im Arbeitsordner alle Dateien, die zu diesem Schema passen – passt die Ordnerstruktur nicht, reicht ein passender Dateiname mit Szene und Take.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: "\(template)|\(settings.sceneLabel)|\(settings.shotLabel)|\(settings.takeLabel)") { await countMatches() }
    }

    @ViewBuilder
    private var matchInfo: some View {
        if let matches {
            let current = activeMatches ?? ClipIndex.shared.scenes.reduce(0) { $0 + $1.takeCount }
            HStack(spacing: 4) {
                Image(systemName: matches > 0 ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(matches > 0 ? .green : .secondary)
                Text(matches == 1 ? "1 vorhandener Take im Arbeitsordner erkannt" : "\(matches) vorhandene Takes im Arbeitsordner erkannt")
                if template.trimmingCharacters(in: .whitespacesAndNewlines) != AppSettings.shared.namingTemplate {
                    Text("(bisher \(current))").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Arbeitsordner wird durchsucht …").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tokenButton(_ title: String, _ token: String) -> some View {
        Button(title) { template += token }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func countMatches() async {
        matches = nil
        guard let scheme = try? NamingScheme(template: template) else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let folder = AppSettings.shared.workingFolder
        let count = await Task.detached(priority: .userInitiated) { ClipIndex.countMatches(in: folder, scheme: scheme) }.value
        guard !Task.isCancelled else { return }
        matches = count
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
