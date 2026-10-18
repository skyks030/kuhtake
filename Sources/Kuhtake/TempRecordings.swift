import AVFoundation
import Foundation

/// Where takes are written while they are being recorded: `~/Movies/Kuhtake/Temp/Aufnahme_<Datum>.tmp`.
///
/// The recorder writes a fragmented movie (see `Recorder`), so a take that was cut off – Kuhtake quit unexpectedly,
/// crashed, the Mac lost power – still plays up to about the last second once its extension is changed from `.tmp`
/// to `.mov` (or `.mp4`). A finished take is *copied* into the project folder and checked there; the temp file stays,
/// marked "gesichert", until the next recording starts. Files that were never stored are never removed automatically.
enum TempRecordings {
    static let fileExtension = "tmp"
    private static let storedMark = " (gesichert als "
    private static let discardedMark = " (verworfen)"

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kuhtake", isDirectory: true)
            .appendingPathComponent("Temp", isDirectory: true)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// A fresh, not yet existing file for the next recording.
    static func newFile() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        writeReadMe()
        let stem = "Aufnahme_\(stamp.string(from: Date()))"
        var url = folder.appendingPathComponent(stem).appendingPathExtension(fileExtension)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)_\(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return url
    }

    /// The take is safely in the project folder: keep the temp file, but mark it, so the next recording replaces it.
    static func markStored(_ url: URL, as target: URL) {
        let name = url.deletingPathExtension().lastPathComponent + storedMark + target.deletingPathExtension().lastPathComponent + ")"
        rename(url, to: name)
    }

    /// Discarded in the naming dialog: also kept until the next recording, just in case.
    static func markDiscarded(_ url: URL) {
        rename(url, to: url.deletingPathExtension().lastPathComponent + discardedMark)
    }

    private static func rename(_ url: URL, to stem: String) {
        let target = url.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(fileExtension)
        try? FileManager.default.moveItem(at: url, to: target)
    }

    /// When a new recording starts: removes the temp files of takes that were stored (or discarded) before.
    static func removeHandled() {
        for url in files() where isHandled(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Recordings that never made it into the project folder (cut off, or still waiting for a name).
    static func unsaved() -> [URL] {
        files().filter { !isHandled($0) }
    }

    private static func isHandled(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.contains(storedMark) || name.contains(discardedMark)
    }

    private static func files() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == fileExtension }
    }

    /// The copy in the project folder is complete: same size and the same playable length as the temp file.
    static func verify(copy: URL, of original: URL) throws {
        let fm = FileManager.default
        let size = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil }
        guard let a = size(original), let b = size(copy), a == b else {
            throw RecorderError.writerFailed("Die Kopie im Projektordner ist unvollständig")
        }
        // The temp file has no movie extension: tell AVFoundation what it is.
        let mime = copy.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
        let source = movieInfo(AVURLAsset(url: original, options: [AVURLAssetOverrideMIMETypeKey: mime]))
        let copied = movieInfo(AVURLAsset(url: copy))
        guard let copied, copied.hasVideo, copied.duration > 0 else {
            throw RecorderError.writerFailed("Die Kopie im Projektordner lässt sich nicht als Film öffnen")
        }
        if let source, abs(source.duration - copied.duration) > 0.01 {
            throw RecorderError.writerFailed("Die Kopie im Projektordner ist kürzer als die Aufnahme")
        }
    }

    /// Blocks: only call from a background queue.
    private static func movieInfo(_ asset: AVURLAsset) -> (duration: Double, hasVideo: Bool)? {
        let done = DispatchSemaphore(value: 0)
        var info: (Double, Bool)?
        Task {
            if let (duration, tracks) = try? await asset.load(.duration, .tracks) {
                info = (duration.seconds, tracks.contains { $0.mediaType == .video })
            }
            done.signal()
        }
        done.wait()
        return info
    }

    private static func writeReadMe() {
        let url = folder.appendingPathComponent("LIESMICH.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        Kuhtake – temporäre Aufnahmen

        Hier schreibt Kuhtake jede Aufnahme, während sie läuft („Aufnahme_<Datum>.tmp“).
        Nach dem Benennen wird sie in den Projektordner kopiert und dort geprüft. Die Datei hier
        bleibt danach mit dem Zusatz „(gesichert als …)“ liegen, bis die nächste Aufnahme startet.

        Aufnahme abgebrochen (Kuhtake abgestürzt, Strom weg …)?
        Die Datei ist trotzdem verwendbar: einfach die Endung „.tmp“ in „.mov“ ändern
        (bei MP4-Aufnahmen „.mp4“). Sie spielt dann bis etwa eine Sekunde vor dem Abbruch.

        Dateien ohne Zusatz wurden nie im Projektordner gespeichert und werden nie automatisch gelöscht.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
