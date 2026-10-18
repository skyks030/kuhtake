import AppKit
import Combine
import SwiftUI

/// ⇧Space: a Raycast-style search bar over the Kuhtake window. Finds takes by scene, shot, take, name, timecode,
/// time of day or length; the best hit is preselected, ↩ jumps to it in the file browser.
@MainActor
enum QuickSearch {
    private static var panel: QuickSearchPanel?
    private static var keyMonitor: Any?

    /// ⇧Space in any Kuhtake window (not while typing in a text field).
    static func installShortcut() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift else { return event }
            if let panel, event.window === panel {
                // Inside the search: ⇧Space closes it only while nothing has been typed.
                guard QuickSearchModel.shared.query.isEmpty else { return event }
                close()
                return nil
            }
            if let tv = event.window?.firstResponder as? NSTextView, tv.isEditable { return event }
            guard event.window != nil else { return event }
            toggle()
            return nil
        }
    }

    static var isOpen: Bool { panel?.isVisible == true }

    static func toggle() {
        isOpen ? close() : open()
    }

    static func open() {
        let model = QuickSearchModel.shared
        model.prepare()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        QuickSearchModel.shared.query = ""
    }

    private static func makePanel() -> QuickSearchPanel {
        let panel = QuickSearchPanel(contentRect: NSRect(x: 0, y: 0, width: QuickSearchView.width, height: 420),
                                     styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: QuickSearchView())
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.onResignKey = { close() }
        return panel
    }

    /// Upper third of the main Kuhtake window (or the screen), like Spotlight / Raycast.
    private static func position(_ panel: NSPanel) {
        let anchor = WindowPresenter.shared.window(PreviewWindow.id).flatMap { $0.isVisible ? $0.frame : nil }
            ?? NSApp.keyWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let size = panel.frame.size
        let x = anchor.midX - size.width / 2
        let top = anchor.maxY - max(60, anchor.height * 0.16)
        panel.setFrameTopLeftPoint(NSPoint(x: x.rounded(), y: top.rounded()))
    }
}

final class QuickSearchPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// ↑ ↓ ↩ ⎋ and ⌘1 / ⌘2 are handled here, before the text field sees them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, QuickSearchModel.shared.handleKey(event) { return }
        super.sendEvent(event)
    }
}

// MARK: - Model

@MainActor
final class QuickSearchModel: ObservableObject {
    static let shared = QuickSearchModel()

    struct Hit: Identifiable, Equatable {
        var id: String { take.id }
        let take: TakeFile
        let score: Double
        /// Why it matched, if not obvious from the name (e.g. "Timecode im Clip").
        let reason: String?
    }

    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var hits: [Hit] = []
    @Published var selectedIndex = 0
    @Published private(set) var meta: [String: TakeInfoCache.Meta] = [:]
    /// Bumped when the panel opens, so the field takes focus again.
    @Published private(set) var focusToken = 0

    private var metaTask: Task<Void, Never>?
    static let maxHits = 8

    /// Loads durations / timecodes of all takes in the background (once per file), then searches.
    func prepare() {
        focusToken += 1
        selectedIndex = 0
        search()
        metaTask?.cancel()
        let takes = ClipIndex.shared.allTakes
        metaTask = Task {
            var batch = 0
            for take in takes.sorted(by: { $0.date > $1.date }) {
                if Task.isCancelled { return }
                if meta[take.id] != nil { continue }
                let m = await TakeInfoCache.shared.meta(for: take)
                meta[take.id] = m
                batch += 1
                if batch % 20 == 0 { search(keepSelection: true) }
            }
            search(keepSelection: true)
        }
    }

    func search(keepSelection: Bool = false) {
        let previous = keepSelection && hits.indices.contains(selectedIndex) ? hits[selectedIndex].id : nil
        let takes = ClipIndex.shared.allTakes
        let matcher = TakeQuery(query, labels: ClipNaming.labels)
        if matcher.isEmpty {
            hits = takes.sorted { $0.date > $1.date }.prefix(Self.maxHits).map { Hit(take: $0, score: 0, reason: nil) }
        } else {
            hits = takes.compactMap { take -> Hit? in
                guard let r = matcher.score(take, meta: meta[take.id]) else { return nil }
                return Hit(take: take, score: r.score, reason: r.reason)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.take.date > $1.take.date }
            .prefix(Self.maxHits)
            .map { $0 }
        }
        selectedIndex = previous.flatMap { id in hits.firstIndex { $0.id == id } } ?? 0
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + hits.count) % hits.count
    }

    func choose(_ hit: Hit? = nil, loadInto monitor: Int? = nil) {
        guard let hit = hit ?? (hits.indices.contains(selectedIndex) ? hits[selectedIndex] : nil) else {
            NSSound.beep()
            return
        }
        QuickSearch.close()
        PreviewModel.shared.reveal(hit.take, loadInto: monitor)
    }

    /// Keys of the panel. true = handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        switch Int(event.keyCode) {
        case 125: move(1); return true                       // ↓
        case 126: move(-1); return true                      // ↑
        case 36, 76: choose(); return true                   // ↩
        case 53: QuickSearch.close(); return true            // ⎋
        case 18 where mods == .command: choose(loadInto: 1); return true  // ⌘1
        case 19 where mods == .command: choose(loadInto: 2); return true  // ⌘2
        default: return false
        }
    }
}

// MARK: - Matching

/// The parsed search text. Every word has to match somewhere; the score says how well.
///
/// Understood: scene ("12A", "SC12A", "szene 12a"), shot / take ("SH3", "TK7", "shot 3"), "12A 3 7" or "12A/3/7"
/// (scene, shot, take), parts of the file name, timecode ("10:11:12:13", "10:11:12" – also inside a clip),
/// time of day ("14:32", "14:32:10"), length ("1:30", "90s", "2m", ">2m", "<30s"), date ("18.10.", "heute", "gestern").
struct TakeQuery {
    struct Result { var score: Double; var reason: String? }

    private enum Field { case scene, shot, take }
    private var words: [String] = []
    private var labels: NamingScheme.Labels

    var isEmpty: Bool { words.isEmpty }

    init(_ text: String, labels: NamingScheme.Labels) {
        self.labels = labels
        var raw = text.lowercased()
            .components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
        // "sc 12a" → "sc12a": a label on its own belongs to the next word.
        var merged: [String] = []
        var i = 0
        while i < raw.count {
            if i + 1 < raw.count, Self.field(prefix: raw[i], labels: labels) != nil, raw[i + 1].first?.isNumber == true || raw[i + 1].first?.isLetter == true,
               Self.field(prefix: raw[i + 1], labels: labels) == nil {
                merged.append(raw[i] + raw[i + 1])
                i += 2
            } else {
                merged.append(raw[i])
                i += 1
            }
        }
        raw = merged
        words = raw
    }

    private static func aliases(_ labels: NamingScheme.Labels) -> [(Field, [String])] {
        func list(_ label: String, _ extra: [String]) -> [String] {
            (([label.lowercased()] + extra).filter { !$0.isEmpty }).sorted { $0.count > $1.count }
        }
        return [(.scene, list(labels.scene, ["szene", "scene", "sc"])),
                (.shot, list(labels.shot, ["einstellung", "shot", "sh"])),
                (.take, list(labels.take, ["take", "tk"]))]
    }

    /// "sh" / "shot" alone.
    private static func field(prefix word: String, labels: NamingScheme.Labels) -> Field? {
        aliases(labels).first { $0.1.contains(word) }?.0
    }

    func score(_ take: TakeFile, meta: TakeInfoCache.Meta?) -> Result? {
        var total = 0.0
        var reasons: [String] = []
        for word in words {
            guard let r = scoreWord(word, take, meta) else { return nil }
            total += r.score
            if let reason = r.reason, !reasons.contains(reason) { reasons.append(reason) }
        }
        total += positionalBonus(take)
        // Newer takes win ties.
        total += max(0, 3 - Date().timeIntervalSince(take.date) / 86_400 / 10)
        return Result(score: total, reason: reasons.isEmpty ? nil : reasons.joined(separator: " · "))
    }

    /// "12A 3 7": scene, then shot, then take.
    private func positionalBonus(_ t: TakeFile) -> Double {
        guard words.count >= 2, words[0] == t.scene.lowercased() else { return 0 }
        let numbers = words.dropFirst().compactMap { Int($0) }
        guard numbers.count == words.count - 1 else { return 0 }
        var bonus = 0.0
        if numbers.count >= 1, numbers[0] == t.shot { bonus += 60 }
        if numbers.count >= 2, numbers[1] == t.take { bonus += 60 }
        return bonus
    }

    private func scoreWord(_ w: String, _ t: TakeFile, _ meta: TakeInfoCache.Meta?) -> Result? {
        var best: Result?
        func offer(_ score: Double, _ reason: String? = nil) {
            if score > (best?.score ?? 0) { best = Result(score: score, reason: reason) }
        }
        let scene = t.scene.lowercased()
        let name = t.name.lowercased()

        // Field with label: "sc12a", "sh3", "tk07", "shot3".
        for (field, names) in Self.aliases(labels) {
            for prefix in names where w.hasPrefix(prefix) && w.count > prefix.count {
                let rest = String(w.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ":=_-"))
                guard !rest.isEmpty else { continue }
                switch field {
                case .scene:
                    if scene == rest { offer(110) } else if scene.hasPrefix(rest) { offer(55) }
                case .shot:
                    if Int(rest) == t.shot { offer(100) }
                case .take:
                    if Int(rest) == t.take { offer(100) }
                }
            }
        }

        // "12a/3/7", "12a-3", "12a_03_07".
        let parts = w.split(whereSeparator: { "/_-.".contains($0) }).map(String.init)
        if parts.count >= 2, parts.count <= 3, !w.contains(":"), parts.dropFirst().allSatisfy({ Int($0) != nil }), !w.contains(".") || parts.count == 3 {
            var ok = scene == parts[0]
            if ok, let s = Int(parts[1]) { ok = s == t.shot }
            if ok, parts.count == 3, let k = Int(parts[2]) { ok = k == t.take }
            if ok { offer(160) }
        }

        if let tc = Self.timecodeParts(w) {
            scoreTime(tc, w, t, meta, offer)
        }
        if let d = Self.duration(w) {
            if let dur = meta?.duration {
                switch d.op {
                case ">": if dur > d.seconds { offer(45, "Länge") }
                case "<": if dur < d.seconds { offer(45, "Länge") }
                default:
                    let tolerance = max(2, d.seconds * 0.2)
                    let diff = abs(dur - d.seconds)
                    if diff <= tolerance { offer(90 * (1 - diff / tolerance / 2), "Länge \(Self.clock(dur))") }
                }
            }
        }
        if let day = Self.day(w), Calendar.current.isDate(t.date, inSameDayAs: day) { offer(60, "Datum") }

        if let n = Int(w) {
            if scene == w { offer(90) }
            if t.take == n { offer(70) }
            if t.shot == n { offer(60) }
            if scene.hasPrefix(w) { offer(35) }
        } else if !w.contains(":") {
            if scene == w { offer(100) }
            if scene.hasPrefix(w) { offer(55) }
        }
        if name.contains(w) { offer(w.count >= 3 ? 45 : 25) }
        if w.count >= 2, Self.isSubsequence(w, of: name) { offer(12) }
        return best
    }

    private func scoreTime(_ tc: [Int], _ w: String, _ t: TakeFile, _ meta: TakeInfoCache.Meta?,
                           _ offer: (Double, String?) -> Void) {
        let duration = meta?.duration ?? 0
        // Timecode of the clip.
        if let start = meta?.timecodeFrames, let q = meta?.timecodeQuanta {
            let startText = TimecodeReader.format(frames: start, quanta: q)
            let frames = Self.frames(tc, quanta: q)
            let end = start + Int((duration * Double(q)).rounded())
            let dayFrames = 24 * 3600 * q
            func inside(_ f: Int) -> Bool {
                end <= dayFrames ? (f >= start && f <= end) : (f >= start || f <= end - dayFrames)
            }
            let normalized = w.replacingOccurrences(of: ";", with: ":").replacingOccurrences(of: ".", with: ":")
            if tc.count >= 3, let frames, inside(frames) { offer(tc.count == 4 ? 140 : 120, "Timecode im Clip") }
            // "hh:mm": the clip runs during that minute.
            else if tc.count == 2, let frames, start < frames + 60 * q, end >= frames { offer(80, "Timecode im Clip") }
            if startText.hasPrefix(normalized) { offer(95, "Start-Timecode") }
        }
        // Time of day of the recording.
        if tc.count <= 3, tc[0] < 24, tc.count >= 2, tc[1] < 60 {
            let cal = Calendar.current
            let c = cal.dateComponents([.hour, .minute, .second], from: t.date)
            let startSec = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
            let querySec = tc[0] * 3600 + tc[1] * 60 + (tc.count == 3 ? tc[2] : 0)
            let endSec = startSec + Int(duration.rounded(.up))
            if tc.count == 2, c.hour == tc[0], c.minute == tc[1] { offer(100, "Aufgenommen \(Self.hhmm(t.date))") }
            else if querySec >= startSec, querySec <= max(endSec, startSec + (tc.count == 2 ? 59 : 0)) {
                offer(85, "Lief um \(w)")
            }
        }
        // Length "m:ss".
        if tc.count == 2, tc[1] < 60, let dur = meta?.duration {
            let seconds = Double(tc[0] * 60 + tc[1])
            let diff = abs(dur - seconds)
            if diff < 1 { offer(95, "Länge \(Self.clock(dur))") } else if diff < 3 { offer(50, "Länge \(Self.clock(dur))") }
        }
    }

    // MARK: Parsing helpers

    /// "10:11:12:13", "10:11:12", "14:32" (also with ; or . between).
    static func timecodeParts(_ w: String) -> [Int]? {
        let parts = w.split(whereSeparator: { ":;".contains($0) }).map(String.init)
        guard parts.count >= 2, parts.count <= 4, parts.allSatisfy({ $0.count <= 2 && Int($0) != nil }) else { return nil }
        return parts.compactMap(Int.init)
    }

    private static func frames(_ tc: [Int], quanta q: Int) -> Int? {
        switch tc.count {
        case 4: return ((tc[0] * 60 + tc[1]) * 60 + tc[2]) * q + tc[3]
        case 3: return ((tc[0] * 60 + tc[1]) * 60 + tc[2]) * q
        case 2: return (tc[0] * 60 + tc[1]) * 60 * q
        default: return nil
        }
    }

    /// "90s", "2m", "1,5min", "1h", optionally with > or <.
    static func duration(_ w: String) -> (op: Character?, seconds: Double)? {
        var s = Substring(w)
        var op: Character?
        if let f = s.first, f == ">" || f == "<" { op = f; s = s.dropFirst() }
        let units: [(String, Double)] = [("min", 60), ("sek", 1), ("sec", 1), ("s", 1), ("m", 60), ("h", 3600)]
        for (unit, factor) in units where s.hasSuffix(unit) {
            let number = s.dropLast(unit.count).replacingOccurrences(of: ",", with: ".")
            if let v = Double(number), v >= 0 { return (op, v * factor) }
        }
        if op != nil, let p = timecodeParts(String(s)), p.count == 2 { return (op, Double(p[0] * 60 + p[1])) }
        return nil
    }

    static func day(_ w: String) -> Date? {
        let cal = Calendar.current
        switch w {
        case "heute", "today": return Date()
        case "gestern", "yesterday": return cal.date(byAdding: .day, value: -1, to: Date())
        default: break
        }
        let parts = w.split(separator: ".", omittingEmptySubsequences: true).compactMap { Int($0) }
        guard w.contains("."), parts.count >= 2, parts.count <= 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]) else { return nil }
        var c = cal.dateComponents([.year], from: Date())
        c.day = parts[0]
        c.month = parts[1]
        if parts.count == 3 { c.year = parts[2] < 100 ? 2000 + parts[2] : parts[2] }
        return cal.date(from: c)
    }

    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func hhmm(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

// MARK: - View

struct QuickSearchView: View {
    static let width: CGFloat = 640
    @ObservedObject private var model = QuickSearchModel.shared
    @ObservedObject private var index = ClipIndex.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Take suchen – Szene, Shot, Take, Name, Timecode, Uhrzeit, Länge …", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Divider().opacity(0.6)

            if model.hits.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(index.allTakes.isEmpty ? "Noch keine Takes im Arbeitsordner" : "Kein Take passt zu „\(model.query)“")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 2) {
                    if model.query.isEmpty {
                        Text("ZULETZT AUFGENOMMEN")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 4)
                    }
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { i, hit in
                        QuickSearchRow(hit: hit, meta: model.meta[hit.id], selected: i == model.selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { model.choose(hit) }
                            .onHover { if $0 { model.selectedIndex = i } }
                    }
                }
                .padding(8)
            }

            Divider().opacity(0.6)
            HStack(spacing: 14) {
                hint("↑↓", "Auswählen")
                hint("↩", "Im File Browser zeigen")
                hint("⌘1 / ⌘2", "In Monitor laden")
                Spacer()
                hint("⎋", "Schließen")
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(width: Self.width)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 14)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption.weight(.semibold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct QuickSearchRow: View {
    let hit: QuickSearchModel.Hit
    let meta: TakeInfoCache.Meta?
    let selected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        let t = hit.take
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black)
                if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.name).font(.system(.body, design: .monospaced).weight(.medium)).lineLimit(1)
                    if let reason = hit.reason {
                        Text(reason)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(selected ? 0.35 : 0.18)))
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "return").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .task(id: t) { thumbnail = await TakeInfoCache.shared.info(for: t).thumbnail }
    }

    private var details: String {
        let t = hit.take
        let shotLabel = ClipNaming.labels.shot.isEmpty ? "Shot " : ClipNaming.labels.shot
        var parts = ["Szene \(t.scene)", shotLabel + ClipName.twoDigits(t.shot), t.label]
        parts.append(t.date.formatted(.dateTime.day().month(.twoDigits).hour().minute()))
        if let d = meta?.duration { parts.append(TakeQuery.clock(d)) }
        if let tc = meta?.timecodeFrames, let q = meta?.timecodeQuanta { parts.append("TC " + TimecodeReader.format(frames: tc, quanta: q)) }
        return parts.joined(separator: " · ")
    }
}

/// Blurred, translucent panel background.
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
