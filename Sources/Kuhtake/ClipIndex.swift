import Combine
import CoreServices
import Foundation

/// One clip on disk, recognised by the user's naming scheme (see `NamingScheme`).
struct TakeFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let scene: String
    let shot: Int
    let take: Int
    /// 1 for the regular file, 2… for `_2`, `_3` (same name stored twice).
    let variant: Int
    let date: Date
    let size: Int64

    var label: String {
        let l = ClipNaming.labels.take
        return (l.isEmpty ? "Take " : l) + ClipName.twoDigits(take) + (variant > 1 ? " (\(variant))" : "")
    }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var clipName: ClipName { ClipName(scene: scene, shot: shot, take: take) }

    init(url: URL, match: NamingScheme.Match, date: Date, size: Int64) {
        self.url = url
        scene = match.scene
        shot = match.shot
        take = match.take
        variant = match.variant
        self.date = date
        self.size = size
    }

    /// Order within a shot: take number, then duplicates, then time.
    static func < (a: TakeFile, b: TakeFile) -> Bool {
        (a.take, a.variant, a.date) < (b.take, b.variant, b.date)
    }
}

/// A shot ("Einstellung") of a scene with its takes, oldest first.
struct ShotGroup: Identifiable, Hashable {
    var id: String { "\(scene)|\(shot)" }
    let scene: String
    let shot: Int
    let takes: [TakeFile]
    var lastTake: TakeFile? { takes.last }
}

struct SceneGroup: Identifiable, Hashable {
    var id: String { scene }
    let scene: String
    let shots: [ShotGroup]
    var takeCount: Int { shots.reduce(0) { $0 + $1.takes.count } }
}

/// Keeps an index of all takes in the working folder, in the background: file system events trigger a
/// rescan, plus a slow periodic rescan for drives that don't report changes (network shares).
final class ClipIndex: ObservableObject {
    static let shared = ClipIndex()

    @Published private(set) var scenes: [SceneGroup] = []
    /// The most recently recorded take overall.
    @Published private(set) var latest: TakeFile?
    @Published private(set) var isScanning = false
    @Published private(set) var folder: URL?

    private let queue = DispatchQueue(label: "kuhtake.clipindex", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var periodic: Timer?
    private var cancellable: AnyCancellable?
    private var schemeCancellable: AnyCancellable?

    func start() {
        cancellable = AppSettings.shared.$workingFolder
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.watch(url) }
        // A different naming scheme recognises different files.
        let st = AppSettings.shared
        schemeCancellable = Publishers.CombineLatest4(st.$namingTemplate, st.$sceneLabel, st.$shotLabel, st.$takeLabel)
            .map { "\($0)|\($1)|\($2)|\($3)" }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescanSoon(delay: 0.2) }
        periodic = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.rescanSoon() }
    }

    /// Debounced, so bursts of file events lead to one scan.
    func rescanSoon(delay: TimeInterval = 0.4) {
        guard let folder else { return }
        pending?.cancel()
        let scheme = ClipNaming.scheme
        let work = DispatchWorkItem { [weak self] in self?.scan(folder, scheme: scheme) }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// How many video files under `root` a (not yet active) scheme would recognise – for the naming editor.
    static func countMatches(in root: URL, scheme: NamingScheme) -> Int {
        Self.findTakes(in: root, scheme: scheme).count
    }

    func shot(of take: TakeFile) -> ShotGroup? {
        scenes.first { $0.scene == take.scene }?.shots.first { $0.shot == take.shot }
    }

    // MARK: Watching

    private func watch(_ url: URL) {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        folder = url
        scenes = []
        latest = nil

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let index = Unmanaged<ClipIndex>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            // Writes into the temp folder during a recording are not interesting.
            if !list.isEmpty, list.allSatisfy({ $0.contains("/.kuhtake-tmp") }) { return }
            DispatchQueue.main.async { index.rescanSoon() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        if let s = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
        rescanSoon(delay: 0)
    }

    // MARK: Scanning (background queue)

    private func scan(_ root: URL, scheme: NamingScheme) {
        DispatchQueue.main.async { self.isScanning = true }
        let takes = Self.findTakes(in: root, scheme: scheme)

        let byScene = Dictionary(grouping: takes, by: \.scene)
        let scenes = byScene.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { scene -> SceneGroup in
                let shots = Dictionary(grouping: byScene[scene]!, by: \.shot)
                    .map { ShotGroup(scene: scene, shot: $0.key, takes: $0.value.sorted(by: <)) }
                    .sorted { $0.shot < $1.shot }
                return SceneGroup(scene: scene, shots: shots)
            }
        let latest = takes.max { $0.date < $1.date }

        DispatchQueue.main.async {
            guard self.folder == root, ClipNaming.scheme == scheme else { return }
            if self.scenes != scenes { self.scenes = scenes }
            if self.latest != latest { self.latest = latest }
            self.isScanning = false
        }
    }

    /// Every video file up to a few folder levels deep whose path fits the scheme (or whose file name does).
    private static func findTakes(in root: URL, scheme: NamingScheme) -> [TakeFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        let matcher = scheme.makeMatcher()
        let rootPath = root.standardizedFileURL.path
        let maxDepth = max(scheme.components.count, 2) + 1
        var takes: [TakeFile] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            if walker.level >= maxDepth { walker.skipDescendants() }
            guard NamingScheme.videoExtensions.contains(url.pathExtension.lowercased()),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            if let t = takeFile(url, values: v, rootPath: rootPath, matcher: matcher) { takes.append(t) }
        }
        return takes
    }

    /// The take a single file is (after renaming it, before the next scan).
    static func takeFile(at url: URL) -> TakeFile? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return takeFile(url, values: v, rootPath: AppSettings.shared.workingFolder.standardizedFileURL.path,
                        matcher: ClipNaming.scheme.makeMatcher())
    }

    private static func takeFile(_ url: URL, values v: URLResourceValues, rootPath: String, matcher: NamingScheme.Matcher) -> TakeFile? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard let m = NamingScheme.match(relative, with: matcher) else { return nil }
        let date = v.creationDate ?? v.contentModificationDate ?? .distantPast
        return TakeFile(url: url, match: m, date: date, size: Int64(v.fileSize ?? 0))
    }

    /// All takes, flattened.
    var allTakes: [TakeFile] { scenes.flatMap { $0.shots.flatMap(\.takes) } }

    func take(id: TakeFile.ID) -> TakeFile? {
        for scene in scenes { for shot in scene.shots { if let t = shot.takes.first(where: { $0.id == id }) { return t } } }
        return nil
    }
}
