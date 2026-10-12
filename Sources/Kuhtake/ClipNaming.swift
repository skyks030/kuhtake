import Foundation

/// Scene / shot / take naming and the files-on-disk side of it.
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

    var sceneFolderName: String { "SC\(Self.sanitize(scene))" }
    var baseFileName: String { "SC\(Self.sanitize(scene))_SH\(Self.twoDigits(shot))_TK\(Self.twoDigits(take))" }
    var display: String { "Szene \(scene) · Shot \(Self.twoDigits(shot)) · Take \(Self.twoDigits(take))" }
}

enum ClipNaming {
    static var next: ClipName {
        let s = AppSettings.shared
        return ClipName(scene: s.scene, shot: s.shot, take: s.take)
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

    /// Moves a finished temp recording into `<working folder>/SC<scene>/<name>.<ext>`.
    static func store(tempFile: URL, as name: ClipName) throws -> URL {
        let fm = FileManager.default
        let folder = AppSettings.shared.workingFolder.appendingPathComponent(name.sceneFolderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = tempFile.pathExtension
        var target = folder.appendingPathComponent(name.baseFileName).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(name.baseFileName)_\(n)").appendingPathExtension(ext)
            n += 1
        }
        try fm.moveItem(at: tempFile, to: target)
        return target
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
