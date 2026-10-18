import AVFoundation
import AppKit
import SwiftUI

/// ⌘F (File Browser): takes of the working folder on the left, monitor 1 in the middle, monitor 2 on the right.
/// 1 / 2 load the selected take into a monitor, Space plays/pauses both, J / K / L shuttle, ⌘R returns to the live picture.
struct SourceBrowserView: View {
    @ObservedObject private var model = PreviewModel.shared
    @ObservedObject private var index = ClipIndex.shared

    /// Width of the take list, remembered between launches (dragged at the divider).
    @AppStorage("browserSidebarWidth") private var sidebarWidth: Double = Self.defaultSidebarWidth
    @State private var dragStartWidth: Double?

    /// Just wide enough for the key hints at the bottom.
    static let defaultSidebarWidth: Double = 270
    static let sidebarRange: ClosedRange<Double> = 220...560

    var body: some View {
        HStack(spacing: 0) {
            TakeSidebar()
                .frame(width: min(max(sidebarWidth, Self.sidebarRange.lowerBound), Self.sidebarRange.upperBound))
            divider
            HStack(spacing: 1) {
                MonitorView(monitor: model.monitor1, number: 1, isLatest: isLatest(model.monitor1))
                if model.showSecondMonitor {
                    MonitorView(monitor: model.monitor2, number: 2, isLatest: isLatest(model.monitor2)) {
                        withAnimation(.easeInOut(duration: 0.2)) { model.closeSecondMonitor() }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Color.black.opacity(0.6))
            .frame(minWidth: 420)
            .animation(.easeInOut(duration: 0.2), value: model.showSecondMonitor)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let start = dragStartWidth ?? sidebarWidth
                            dragStartWidth = start
                            sidebarWidth = min(max(start + v.translation.width, Self.sidebarRange.lowerBound), Self.sidebarRange.upperBound)
                        }
                        .onEnded { _ in dragStartWidth = nil })
                    .onTapGesture(count: 2) { sidebarWidth = Self.defaultSidebarWidth }
                    .help("Ziehen ändert die Breite · Doppelklick: Standardbreite")
            )
    }

    private func isLatest(_ m: MonitorPlayer) -> Bool {
        m.take != nil && m.take == index.latest
    }
}

private struct TakeSidebar: View {
    @ObservedObject private var model = PreviewModel.shared
    @ObservedObject private var index = ClipIndex.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var renaming: TakeFile?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if index.scenes.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selection) {
                        ForEach(index.scenes) { scene in
                            DisclosureGroup(isExpanded: expanded(scene.id)) {
                                ForEach(scene.shots) { shot in
                                    DisclosureGroup(isExpanded: expanded(shot.id)) {
                                        ForEach(visibleTakes(of: shot)) { take in
                                            TakeRow(take: take, isLast: take == shot.lastTake, isNewest: take == index.latest,
                                                    onMonitor1: model.monitor1.take == take,
                                                    onMonitor2: model.showSecondMonitor && model.monitor2.take == take)
                                                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                                                .tag(take.id)
                                                .id(take.id)
                                                .draggable(take.id)
                                                .contextMenu { contextMenu(for: take) }
                                        }
                                    } label: {
                                        ShotRow(shot: shot)
                                            .dropTarget { ids in model.move(ids, toScene: shot.scene, shot: shot.shot) }
                                    }
                                }
                            } label: {
                                SceneRow(scene: scene)
                                    .dropTarget { ids in model.move(ids, toScene: scene.scene, shot: nil) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onDeleteCommand { model.deleteRequest = model.selectedTake }
                    .help("Takes auf eine Einstellung oder Szene ziehen, um sie zu verschieben · ⌫ legt den Take in den Papierkorb")
                    .onChange(of: model.selection) { _, id in
                        guard let id else { return }
                        reveal(id)
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = model.selection {
                            reveal(id)
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $renaming) { take in
            RenameTakeView(take: take) { name in
                model.rename(take, to: name)
                renaming = nil
            } onCancel: {
                renaming = nil
            }
        }
        .alert("Take in den Papierkorb legen?", isPresented: Binding(get: { model.deleteRequest != nil },
                                                                      set: { if !$0 { model.deleteRequest = nil } }),
               presenting: model.deleteRequest) { take in
            Button("In den Papierkorb", role: .destructive) { model.delete(take) }
            Button("Abbrechen", role: .cancel) {}
        } message: { take in
            Text("„\(take.url.lastPathComponent)“ wird in den Papierkorb gelegt und kann von dort im Finder wiederhergestellt werden.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Takes").font(.headline)
                Text(index.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "–")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if index.isScanning { ProgressView().controlSize(.mini) }
            Button {
                settings.browserLastTakesOnly.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.browserLastTakesOnly
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.title3)
                    Text("Nur letzte Takes").font(.caption)
                }
                .foregroundStyle(settings.browserLastTakesOnly ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(settings.browserLastTakesOnly ? "Alle Takes zeigen" : "Nur den letzten Take jeder Einstellung zeigen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                KeyHint(key: "1", text: "Monitor 1")
                KeyHint(key: "2", text: "Monitor 2")
                KeyHint(key: "␣", text: "Play")
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                KeyHint(key: "J K L", text: "Shuttle")
                KeyHint(key: "⇧␣", text: "Suchen")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help("J / L: rückwärts / vorwärts abspielen, mehrmals drücken für 2×, 4×, 8× · K: Stopp · ⇧Leertaste: Take suchen")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "film.stack").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Noch keine Takes im Arbeitsordner").foregroundStyle(.secondary)
            Text("Erkannt werden Dateien nach dem Namensschema\n\(settings.namingTemplate)")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Button("Namensschema anpassen …") { SettingsWindow.show(tab: .naming) }
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    private func contextMenu(for take: TakeFile) -> some View {
        Button("In Monitor 1 laden") { model.selection = take.id; model.load(into: 1) }
        Button("In Monitor 2 laden") { model.selection = take.id; model.load(into: 2) }
        Divider()
        Button("Umbenennen …") { renaming = take }
        Menu("Verschieben nach") {
            ForEach(index.scenes) { scene in
                Menu("Szene \(scene.scene)") {
                    ForEach(scene.shots) { shot in
                        Button("Shot \(ClipName.twoDigits(shot.shot))") { model.move([take.id], toScene: scene.scene, shot: shot.shot) }
                            .disabled(shot.scene == take.scene && shot.shot == take.shot)
                    }
                    Divider()
                    Button("Neuer Shot \(ClipName.twoDigits((scene.shots.map(\.shot).max() ?? 0) + 1))") {
                        model.move([take.id], toScene: scene.scene, shot: (scene.shots.map(\.shot).max() ?? 0) + 1)
                    }
                }
            }
        }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([take.url]) }
        Divider()
        Button("In den Papierkorb legen …", role: .destructive) { model.deleteRequest = take }
    }

    private func visibleTakes(of shot: ShotGroup) -> [TakeFile] {
        settings.browserLastTakesOnly ? shot.lastTake.map { [$0] } ?? [] : shot.takes
    }

    /// Folded scenes / shots are remembered (also across launches).
    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !settings.browserCollapsed.contains(id) }, set: { open in
            if open { settings.browserCollapsed.remove(id) } else { settings.browserCollapsed.insert(id) }
        })
    }

    /// Opens the scene and shot of the selected take.
    private func reveal(_ id: TakeFile.ID) {
        guard let take = model.selectedTake else { return }
        let ids: Set<String> = [take.scene, "\(take.scene)|\(take.shot)"]
        if !settings.browserCollapsed.isDisjoint(with: ids) { settings.browserCollapsed.subtract(ids) }
    }
}

/// Highlights a scene / shot row while takes are dragged over it.
private struct DropTarget: ViewModifier {
    let onDrop: ([String]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? Color.accentColor.opacity(0.25) : .clear))
            .dropDestination(for: String.self) { ids, _ in
                onDrop(ids)
                return !ids.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

private extension View {
    func dropTarget(_ onDrop: @escaping ([String]) -> Void) -> some View { modifier(DropTarget(onDrop: onDrop)) }
}

/// Scene / shot / take of an existing file, renamed according to the naming scheme.
private struct RenameTakeView: View {
    let take: TakeFile
    let onRename: (ClipName) -> Void
    let onCancel: () -> Void

    @State private var scene: String
    @State private var shot: Int
    @State private var takeNumber: Int

    init(take: TakeFile, onRename: @escaping (ClipName) -> Void, onCancel: @escaping () -> Void) {
        self.take = take
        self.onRename = onRename
        self.onCancel = onCancel
        _scene = State(initialValue: take.scene)
        _shot = State(initialValue: take.shot)
        _takeNumber = State(initialValue: take.take)
    }

    private var name: ClipName { ClipName(scene: scene.trimmingCharacters(in: .whitespaces), shot: shot, take: takeNumber) }
    private var unchanged: Bool { name == take.clipName }
    private var collides: Bool {
        ClipIndex.shared.allTakes.contains { $0 != take && $0.clipName == name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Take umbenennen").font(.headline)
            Text(take.url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
            Form {
                TextField("Szene", text: $scene)
                Stepper(value: $shot, in: 1...99) { LabeledContent("Shot", value: ClipName.twoDigits(shot)) }
                    .disabled(!ClipNaming.scheme.hasShot)
                Stepper(value: $takeNumber, in: 1...999) { LabeledContent("Take", value: ClipName.twoDigits(takeNumber)) }
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(ClipNaming.scheme.relativePath(for: name, date: take.date) + "." + take.url.pathExtension)
                    .font(.callout.monospaced()).textSelection(.enabled)
            }
            if collides {
                Label("Diesen Take gibt es schon – die Datei bekommt die Endung _2.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Umbenennen") { onRename(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(unchanged || name.scene.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct SceneRow: View {
    let scene: SceneGroup
    var body: some View {
        HStack {
            Label {
                Text("Szene \(scene.scene)").fontWeight(.semibold)
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text("\(scene.takeCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct ShotRow: View {
    let shot: ShotGroup

    /// "SH03" – the shot label from the naming settings.
    private var shotTitle: String {
        let l = ClipNaming.labels.shot
        return (l.isEmpty ? "Shot " : l) + ClipName.twoDigits(shot.shot)
    }
    var body: some View {
        HStack {
            Label {
                Text(shotTitle).font(.body.monospaced())
            } icon: {
                Image(systemName: "camera.fill").foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(shot.takes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct TakeRow: View {
    let take: TakeFile
    let isLast: Bool
    let isNewest: Bool
    let onMonitor1: Bool
    let onMonitor2: Bool

    @State private var thumbnail: CGImage?
    @State private var duration: Double?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.black)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 48, height: 27)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(take.label).font(.system(.body, design: .monospaced).weight(isLast ? .semibold : .regular))
                    if isNewest {
                        Circle().fill(Color.green).frame(width: 6, height: 6).help("Zuletzt aufgenommen")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if onMonitor1 { MonitorBadge(number: 1) }
            if onMonitor2 { MonitorBadge(number: 2) }
        }
        .opacity(isLast || onMonitor1 || onMonitor2 ? 1 : 0.8)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(monitorHighlight)
        .task(id: take) { await loadInfo() }
    }

    /// The whole row in the colour of the monitor showing this take (green = 1, yellow = 2, both = split).
    @ViewBuilder
    private var monitorHighlight: some View {
        let colors = (onMonitor1 ? [MonitorColor.color(1)] : []) + (onMonitor2 ? [MonitorColor.color(2)] : [])
        if !colors.isEmpty {
            let shape = RoundedRectangle(cornerRadius: 6)
            let fill = colors.count == 1
                ? LinearGradient(colors: [colors[0], colors[0]], startPoint: .leading, endPoint: .trailing)
                : LinearGradient(stops: [.init(color: colors[0], location: 0), .init(color: colors[0], location: 0.5),
                                         .init(color: colors[1], location: 0.5), .init(color: colors[1], location: 1)],
                                 startPoint: .leading, endPoint: .trailing)
            shape.fill(fill.opacity(0.28))
                .overlay(shape.strokeBorder(fill.opacity(0.85), lineWidth: 1.5))
        }
    }

    private var subtitle: String {
        let time = take.date.formatted(date: .omitted, time: .shortened)
        guard let duration else { return time }
        let s = Int(duration.rounded())
        return "\(time) · \(String(format: "%d:%02d", s / 60, s % 60))"
    }

    private func loadInfo() async {
        let info = await TakeInfoCache.shared.info(for: take)
        thumbnail = info.thumbnail
        duration = info.duration
    }
}

private struct MonitorBadge: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(number == 2 ? Color.black : .white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(MonitorColor.color(number)))
    }
}

/// Monitor 1 is green, monitor 2 yellow – the frame around the monitor, its badge and the take rows showing it.
enum MonitorColor {
    static func color(_ number: Int) -> Color {
        number == 1 ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color(red: 0.98, green: 0.78, blue: 0.1)
    }
}

private struct KeyHint: View {
    let key: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.weight(.semibold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Thumbnails, durations and start timecodes, generated once per file version.
actor TakeInfoCache {
    static let shared = TakeInfoCache()
    struct Info { var thumbnail: CGImage?; var duration: Double? }
    /// What the quick search needs (no thumbnail – cheap enough for every take).
    struct Meta {
        var duration: Double?
        /// Start timecode in frames since midnight, from the QuickTime timecode track.
        var timecodeFrames: Int?
        var timecodeQuanta: Int = 25
    }
    private var cache: [String: Info] = [:]
    private var metaCache: [String: Meta] = [:]

    private func key(_ take: TakeFile) -> String { "\(take.url.path)|\(take.size)" }

    func info(for take: TakeFile) async -> Info {
        let key = key(take)
        if let hit = cache[key] { return hit }
        let meta = await meta(for: take)
        let asset = AVURLAsset(url: take.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 90)
        let at = CMTime(seconds: min(1, (meta.duration ?? 0) / 2), preferredTimescale: 600)
        let image = try? await gen.image(at: at).image
        let info = Info(thumbnail: image, duration: meta.duration)
        cache[key] = info
        return info
    }

    /// Already known metadata, without loading anything.
    func cachedMeta(for take: TakeFile) -> Meta? { metaCache[key(take)] }

    func meta(for take: TakeFile) async -> Meta {
        let key = key(take)
        if let hit = metaCache[key] { return hit }
        let asset = AVURLAsset(url: take.url)
        var meta = Meta()
        let duration = (try? await asset.load(.duration))?.seconds
        meta.duration = duration.flatMap { $0.isFinite ? $0 : nil }
        if let track = try? await asset.loadTracks(withMediaType: .timecode).first {
            (meta.timecodeFrames, meta.timecodeQuanta) = Self.startTimecode(asset: asset, track: track)
        }
        metaCache[key] = meta
        return meta
    }

    /// First sample of a 'tmcd' track: a big-endian frame number.
    private static func startTimecode(asset: AVAsset, track: AVAssetTrack) -> (Int?, Int) {
        guard let reader = try? AVAssetReader(asset: asset) else { return (nil, 25) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return (nil, 25) }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else { return (nil, 25) }
        defer { reader.cancelReading() }
        var quanta = 25
        if let fmt = sample.formatDescription {
            quanta = max(1, Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fmt)))
        }
        guard let block = sample.dataBuffer, CMBlockBufferGetDataLength(block) >= 4 else { return (nil, quanta) }
        var raw: UInt32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw) == noErr else { return (nil, quanta) }
        return (Int(UInt32(bigEndian: raw)), quanta)
    }
}

// MARK: - Organizing takes

extension PreviewModel {
    /// Drag & drop / "Verschieben nach": into another shot (or only another scene, keeping the shot number).
    /// The take number is kept unless the target shot already has it – then the take becomes the next free one.
    func move(_ ids: [String], toScene scene: String, shot: Int?) {
        let index = ClipIndex.shared
        for id in ids {
            guard let take = index.take(id: id) else { continue }
            let targetShot = shot ?? take.shot
            guard take.scene != scene || take.shot != targetShot else { continue }
            let existing = index.scenes.first { $0.scene == scene }?.shots.first { $0.shot == targetShot }?.takes.map(\.take) ?? []
            let number = existing.contains(take.take) ? (existing.max() ?? 0) + 1 : take.take
            rename(take, to: ClipName(scene: scene, shot: targetShot, take: number))
        }
    }

    func rename(_ take: TakeFile, to name: ClipName) {
        let on1 = monitor1.take == take, on2 = monitor2.take == take
        // Let go of the file while it moves.
        if on1 { monitor1.unload() }
        if on2 { monitor2.unload() }
        do {
            let url = try ClipNaming.move(take, to: name)
            let moved = ClipIndex.takeFile(at: url)
            if let moved {
                if on1 { monitor1.load(moved) }
                if on2 { monitor2.load(moved) }
            }
            selection = url.path
            AppController.shared.showMessage("Umbenannt: \(url.lastPathComponent)")
        } catch {
            if on1 { monitor1.load(take) }
            if on2 { monitor2.load(take) }
            AppController.shared.notify("„\(take.url.lastPathComponent)“ konnte nicht umbenannt werden: \(error.localizedDescription)")
        }
        ClipIndex.shared.rescanSoon(delay: 0)
    }

    func delete(_ take: TakeFile) {
        if monitor1.take == take { monitor1.unload() }
        if monitor2.take == take { monitor2.unload() }
        do {
            try ClipNaming.trash(take)
            if selection == take.id { selection = nil }
            AppController.shared.showMessage("In den Papierkorb gelegt: \(take.url.lastPathComponent)")
        } catch {
            AppController.shared.notify("„\(take.url.lastPathComponent)“ konnte nicht gelöscht werden: \(error.localizedDescription)")
        }
        ClipIndex.shared.rescanSoon(delay: 0)
    }
}
