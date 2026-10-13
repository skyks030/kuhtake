import Foundation

/// Scene / shot / take of one clip. How it turns into folders and file names is up to the `NamingScheme`.
struct ClipName: Equatable {
    var scene: String
    var shot: Int
    var take: Int

    static func sanitize(_ scene: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = scene.components(separatedBy: forbidden).joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "0" : cleaned
    }

    static func twoDigits(_ n: Int) -> String { String(format: "%02d", max(0, n)) }

    var display: String { "Szene \(scene) · Shot \(Self.twoDigits(shot)) · Take \(Self.twoDigits(take))" }
}

// MARK: - Naming scheme

/// A user-defined path template such as `SC{szene}/SC{szene}_SH{shot}_TK{take}`: `/` separates folders,
/// the last part is the file name (without extension). The same template names new clips and recognises
/// existing files in the working folder – so an older folder structure is found by describing its names.
///
/// Placeholders (case-insensitive): `{szene}` / `{scene}`, `{shot}` / `{einstellung}`, `{take}`, `{datum}` / `{date}`
/// (YYMMDD). Numbers can get a width: `{take:3}` → `007`.
struct NamingScheme: Equatable {
    static let defaultTemplate = "SC{szene}/SC{szene}_SH{shot}_TK{take}"
    static let videoExtensions = ["mov", "mp4", "m4v"]

    struct Preset: Identifiable {
        var id: String { template }
        let title: String
        let template: String
    }

    static let presets: [Preset] = [
        Preset(title: "Kuhtake-Standard", template: defaultTemplate),
        Preset(title: "Ordner je Szene und Shot", template: "SC{szene}/SH{shot}/SC{szene}_SH{shot}_TK{take}"),
        Preset(title: "Szene-Shot-Take, ein Ordner", template: "{szene}-{shot}-{take}"),
        Preset(title: "S/E/T mit Datum", template: "{datum}/S{szene}_E{shot}_T{take:3}"),
        Preset(title: "Szene_Take (ohne Shot)", template: "{szene}/{szene}_T{take}"),
    ]

    enum Field: String { case scene, shot, take, date }

    enum Token: Equatable {
        case literal(String)
        case field(Field, width: Int)
    }

    enum ParseError: LocalizedError, Equatable {
        case empty, unknownPlaceholder(String), unclosedBrace, emptyPart, missingTake, missingScene, forbidden(Character)
        var errorDescription: String? {
            switch self {
            case .empty: return "Das Schema ist leer."
            case .unknownPlaceholder(let p): return "Unbekannter Platzhalter „{\(p)}“ – erlaubt sind {szene}, {shot}, {take} und {datum}."
            case .unclosedBrace: return "Eine geschweifte Klammer ist nicht geschlossen."
            case .emptyPart: return "Ein Ordner- oder Dateiname ist leer (doppeltes oder abschließendes „/“)."
            case .missingTake: return "Der Dateiname (nach dem letzten „/“) braucht {take}."
            case .missingScene: return "{szene} muss im Schema vorkommen."
            case .forbidden(let c): return "Das Zeichen „\(c)“ ist in Datei- und Ordnernamen nicht erlaubt."
            }
        }
    }

    let template: String
    /// One token list per path component; the last one is the file name.
    let components: [[Token]]

    var hasShot: Bool { components.contains { $0.contains { if case .field(.shot, _) = $0 { return true }; return false } } }

    init(template: String) throws {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        var comps: [[Token]] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.trimmingCharacters(in: .whitespaces).isEmpty else { throw ParseError.emptyPart }
            comps.append(try Self.tokenize(String(part)))
        }
        guard let file = comps.last, file.contains(where: { if case .field(.take, _) = $0 { return true }; return false }) else {
            throw ParseError.missingTake
        }
        guard comps.joined().contains(where: { if case .field(.scene, _) = $0 { return true }; return false }) else {
            throw ParseError.missingScene
        }
        self.template = trimmed
        components = comps
    }

    static func validate(_ template: String) -> ParseError? {
        do { _ = try NamingScheme(template: template); return nil } catch { return error as? ParseError ?? .empty }
    }

    private static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "{" {
                guard let close = s[i...].firstIndex(of: "}") else { throw ParseError.unclosedBrace }
                let inner = s[s.index(after: i)..<close]
                let parts = inner.split(separator: ":", maxSplits: 1)
                let name = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                let width = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                let field: Field
                switch name {
                case "szene", "scene", "sc": field = .scene
                case "shot", "einstellung", "sh": field = .shot
                case "take", "tk": field = .take
                case "datum", "date": field = .date
                default: throw ParseError.unknownPlaceholder(String(inner))
                }
                if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
                tokens.append(.field(field, width: min(max(width ?? (field == .scene ? 0 : 2), 0), 6)))
                i = s.index(after: close)
            } else {
                if "\\:*?\"<>|".contains(c) { throw ParseError.forbidden(c) }
                if c == "}" { throw ParseError.unclosedBrace }
                literal.append(c)
                i = s.index(after: i)
            }
        }
        if !literal.isEmpty { tokens.append(.literal(literal)) }
        return tokens
    }

    // MARK: Building names

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd"
        return f
    }()

    /// Folder and file name (without extension) relative to the working folder.
    func relativePath(for name: ClipName, date: Date = Date()) -> String {
        components.map { comp in
            comp.map { token -> String in
                switch token {
                case .literal(let s): return s
                case .field(.scene, _): return ClipName.sanitize(name.scene)
                case .field(.shot, let w): return Self.pad(name.shot, w)
                case .field(.take, let w): return Self.pad(name.take, w)
                case .field(.date, _): return Self.dateFormatter.string(from: date)
                }
            }.joined()
        }.joined(separator: "/")
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(max(0, n))
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    // MARK: Recognising files

    struct Match: Equatable {
        var scene: String
        var shot: Int
        var take: Int
        /// 1 for the regular file, 2… for `_2`, `_3` (same name stored twice).
        var variant: Int
    }

    fileprivate struct Pattern {
        let regex: NSRegularExpression
        /// Field of each capture group, in order.
        let groups: [Field]
    }

    private var fullPattern: Pattern { Self.pattern(for: components) }
    private var filePattern: Pattern { Self.pattern(for: [components.last!]) }

    /// Compiled once per scheme (the index calls `match` for every file).
    final class Matcher {
        fileprivate let full: Pattern
        fileprivate let file: Pattern
        fileprivate init(full: Pattern, file: Pattern) { self.full = full; self.file = file }
    }

    func makeMatcher() -> Matcher { Matcher(full: fullPattern, file: filePattern) }

    /// Matches `relativePath` (with extension, `/`-separated) against the whole template. If the folders don't
    /// fit, the file name alone is tried – as long as it carries the scene itself.
    static func match(_ relativePath: String, with matcher: Matcher) -> Match? {
        if let m = apply(matcher.full, to: relativePath) { return m }
        let fileName = (relativePath as NSString).lastPathComponent
        guard matcher.file.groups.contains(.scene) else { return nil }
        return apply(matcher.file, to: fileName)
    }

    private static func pattern(for comps: [[Token]]) -> Pattern {
        var groups: [Field] = []
        var parts: [String] = []
        for comp in comps {
            var s = ""
            for (i, token) in comp.enumerated() {
                switch token {
                case .literal(let lit):
                    s += NSRegularExpression.escapedPattern(for: lit)
                case .field(let f, let w):
                    // Two numbers right after each other only separate with a fixed width.
                    let next = i + 1 < comp.count ? comp[i + 1] : nil
                    let fixed: Bool
                    if case .field = next { fixed = true } else { fixed = false }
                    switch f {
                    case .scene: s += "([^/]+?)"
                    case .shot, .take: s += fixed && w > 0 ? "(\\d{\(w)})" : "(\\d+)"
                    case .date: s += "(\\d{6})"
                    }
                    groups.append(f)
                }
            }
            parts.append(s)
        }
        let exts = videoExtensions.joined(separator: "|")
        let p = "^" + parts.joined(separator: "/") + "(?:_(\\d+))?\\.(?:\(exts))$"
        return Pattern(regex: try! NSRegularExpression(pattern: p, options: [.caseInsensitive]), groups: groups)
    }

    private static func apply(_ p: Pattern, to s: String) -> Match? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = p.regex.firstMatch(in: s, range: range) else { return nil }
        var scene: String?, shot: Int?, take: Int?
        for (i, field) in p.groups.enumerated() {
            guard let r = Range(m.range(at: i + 1), in: s) else { return nil }
            let value = String(s[r])
            switch field {
            case .scene:
                // The same placeholder twice (folder and file) must agree.
                if let scene, scene.caseInsensitiveCompare(value) != .orderedSame { return nil }
                scene = scene ?? value
            case .shot:
                guard let n = Int(value), shot == nil || shot == n else { return nil }
                shot = n
            case .take:
                guard let n = Int(value), take == nil || take == n else { return nil }
                take = n
            case .date:
                break
            }
        }
        guard let scene, let take else { return nil }
        let variantRange = m.range(at: p.groups.count + 1)
        let variant = Range(variantRange, in: s).flatMap { Int(s[$0]) } ?? 1
        return Match(scene: scene, shot: shot ?? 1, take: take, variant: variant)
    }
}

// MARK: - Files on disk

enum ClipNaming {
    static var next: ClipName {
        let s = AppSettings.shared
        return ClipName(scene: s.scene, shot: s.shot, take: s.take)
    }

    /// The active scheme (falls back to the standard one should the stored template be broken).
    static var scheme: NamingScheme {
        (try? NamingScheme(template: AppSettings.shared.namingTemplate)) ?? (try! NamingScheme(template: NamingScheme.defaultTemplate))
    }

    /// e.g. `SC12/SC12_SH01_TK03.mov`
    static func previewPath(for name: ClipName, scheme: NamingScheme = scheme) -> String {
        "\(scheme.relativePath(for: name)).\(AppSettings.shared.effectiveContainer.fileExtension)"
    }

    /// File name of the next clip, without folders and extension.
    static var nextFileName: String {
        (scheme.relativePath(for: next) as NSString).lastPathComponent
    }

    /// Remembers `used` and sets the counter to the following take.
    static func advance(after used: ClipName) {
        let s = AppSettings.shared
        s.scene = used.scene
        s.shot = used.shot
        s.take = min(used.take + 1, 999)
    }

    static func setNext(_ name: ClipName) {
        let s = AppSettings.shared
        s.scene = name.scene
        s.shot = name.shot
        s.take = name.take
    }

    /// Moves a finished temp recording to its place according to the naming scheme.
    static func store(tempFile: URL, as name: ClipName) throws -> URL {
        try place(tempFile, at: scheme.relativePath(for: name))
    }

    /// Renames / moves an existing take (source browser). Keeps the file's date for a `{datum}` placeholder.
    static func move(_ take: TakeFile, to name: ClipName) throws -> URL {
        let path = scheme.relativePath(for: name, date: take.date)
        let target = AppSettings.shared.workingFolder.appendingPathComponent(path).appendingPathExtension(take.url.pathExtension)
        if target.standardizedFileURL.path == take.url.standardizedFileURL.path { return take.url }
        let oldFolder = take.url.deletingLastPathComponent()
        let moved = try place(take.url, at: path)
        removeIfEmpty(oldFolder)
        return moved
    }

    /// Into the trash (can be put back from the Finder).
    static func trash(_ take: TakeFile) throws {
        let folder = take.url.deletingLastPathComponent()
        try FileManager.default.trashItem(at: take.url, resultingItemURL: nil)
        removeIfEmpty(folder)
    }

    private static func place(_ file: URL, at relativePath: String) throws -> URL {
        let fm = FileManager.default
        let base = AppSettings.shared.workingFolder.appendingPathComponent(relativePath)
        let folder = base.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = file.pathExtension
        let stem = base.lastPathComponent
        var target = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)_\(n)").appendingPathExtension(ext)
            n += 1
        }
        try fm.moveItem(at: file, to: target)
        return target
    }

    /// Cleans up scene/shot folders that a move or delete left empty (never the working folder itself).
    private static func removeIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        let root = AppSettings.shared.workingFolder.standardizedFileURL.path
        var current = folder.standardizedFileURL
        while current.path.hasPrefix(root + "/"), current.path != root {
            let items = (try? fm.contentsOfDirectory(atPath: current.path)) ?? ["?"]
            guard items.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    static func tempFolder() throws -> URL {
        let fm = FileManager.default
        var folder = AppSettings.shared.workingFolder.appendingPathComponent(".kuhtake-tmp", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            // Working folder unavailable (e.g. unplugged drive) – fall back to ~/Movies.
            folder = fm.urls(for: .moviesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Kuhtake/.kuhtake-tmp", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
}
