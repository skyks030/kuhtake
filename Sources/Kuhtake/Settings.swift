import AVFoundation
import Combine
import Foundation

// MARK: - Format options

enum ContainerFormat: String, CaseIterable, Codable, Identifiable {
    case mov, mp4
    var id: String { rawValue }
    var label: String { self == .mov ? "QuickTime (.mov)" : "MPEG-4 (.mp4)" }
    var fileExtension: String { rawValue }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
}

enum VideoCodecOption: String, CaseIterable, Codable, Identifiable {
    case h264, hevc, proRes422Proxy, proRes422LT, proRes422, proRes422HQ
    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .proRes422Proxy: return "Apple ProRes 422 Proxy"
        case .proRes422LT: return "Apple ProRes 422 LT"
        case .proRes422: return "Apple ProRes 422"
        case .proRes422HQ: return "Apple ProRes 422 HQ"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        }
    }

    var isProRes: Bool { self != .h264 && self != .hevc }
}

enum ResolutionMode: String, CaseIterable, Codable, Identifiable {
    case native, hd720, hd1080, uhd2160
    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Native Auflösung der Quelle"
        case .hd720: return "1280 × 720 (Letterbox)"
        case .hd1080: return "1920 × 1080 (Letterbox)"
        case .uhd2160: return "3840 × 2160 (Letterbox)"
        }
    }

    var fixedSize: CGSize? {
        switch self {
        case .native: return nil
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .uhd2160: return CGSize(width: 3840, height: 2160)
        }
    }
}

enum FrameRateOption: String, CaseIterable, Codable, Identifiable {
    case fps23_976 = "23.976", fps24 = "24", fps25 = "25", fps29_97 = "29.97"
    case fps30 = "30", fps50 = "50", fps59_94 = "59.94", fps60 = "60"
    var id: String { rawValue }
    var label: String { "\(rawValue) fps" }

    var frameDuration: CMTime {
        switch self {
        case .fps23_976: return CMTime(value: 1001, timescale: 24000)
        case .fps24: return CMTime(value: 1, timescale: 24)
        case .fps25: return CMTime(value: 1, timescale: 25)
        case .fps29_97: return CMTime(value: 1001, timescale: 30000)
        case .fps30: return CMTime(value: 1, timescale: 30)
        case .fps50: return CMTime(value: 1, timescale: 50)
        case .fps59_94: return CMTime(value: 1001, timescale: 60000)
        case .fps60: return CMTime(value: 1, timescale: 60)
        }
    }

    var nominal: Double { 1.0 / frameDuration.seconds }
}

enum RegionShape: String, CaseIterable, Codable, Identifiable {
    case rectangle, ellipse
    var id: String { rawValue }
    var label: String { self == .rectangle ? "Rechteck" : "Kreis / Ellipse" }
}

// MARK: - Capture source

struct CaptureSource: Codable, Equatable {
    enum Kind: String, Codable { case window, display, decklink, vuer, teradek }
    var kind: Kind
    var windowID: UInt32?
    var displayID: UInt32?
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    /// Persistent ID of a Blackmagic DeckLink / UltraStudio input.
    var deckLinkID: String?
    /// Teradek network stream: encoder address or stream URL (rtsp://, udp://@:port, tcp://, http…m3u8), see `StreamAddress`.
    var streamURL: String?
    var label: String
    /// Window / screen sources: only this part of the picture (normalized, top-left origin). nil = everything.
    var crop: CGRect?

    static func deckLink(_ device: DeckLinkDevice) -> CaptureSource {
        CaptureSource(kind: .decklink, deckLinkID: device.id, label: "Blackmagic: \(device.name)")
    }

    /// The Teradek VUER app's window, found again by its bundle ID whenever the app (re)starts.
    static func vuer(_ app: VuerApp = .hdr) -> CaptureSource {
        CaptureSource(kind: .vuer, appBundleID: app.bundleID, appName: app.name, label: "Teradek \(app.name)")
    }

    /// The video stream a Teradek encoder (Serv Pro, Cube …) sends over the network, received and decoded natively.
    static func teradek(address: String, name: String? = nil) -> CaptureSource {
        CaptureSource(kind: .teradek, streamURL: address, label: "Teradek-Stream: \(name ?? address)")
    }

    /// Screen, window and VUER capture need the screen recording permission, DeckLink and network streams don't.
    var needsScreenCapturePermission: Bool { isScreenCapture }
    /// Captured via ScreenCaptureKit (a part of the picture can be cut out).
    var isScreenCapture: Bool { kind != .decklink && kind != .teradek }

    func isSame(as other: CaptureSource) -> Bool {
        guard kind == other.kind else { return false }
        if kind == .vuer { return appBundleID == other.appBundleID }
        if kind == .teradek { return streamURL == other.streamURL }
        return windowID == other.windowID && displayID == other.displayID && deckLinkID == other.deckLinkID
    }
}

// MARK: - Settings store

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var workingFolder: URL { didSet { d.set(workingFolder.path, forKey: "workingFolder") } }
    @Published var showNamingPrompt: Bool { didSet { d.set(showNamingPrompt, forKey: "showNamingPrompt") } }

    @Published var container: ContainerFormat { didSet { save(container, "container") } }
    @Published var codec: VideoCodecOption { didSet { save(codec, "codec") } }
    @Published var resolution: ResolutionMode { didSet { save(resolution, "resolution") } }
    @Published var frameRate: FrameRateOption { didSet { save(frameRate, "frameRate") } }
    @Published var bitrateMbps: Double { didSet { d.set(bitrateMbps, forKey: "bitrateMbps") } }
    @Published var recordAudio: Bool { didSet { d.set(recordAudio, forKey: "recordAudio") } }
    @Published var showCursor: Bool { didSet { d.set(showCursor, forKey: "showCursor") } }

    @Published var source: CaptureSource? { didSet { save(source, "source") } }

    @Published var autoRecordEnabled: Bool { didSet { d.set(autoRecordEnabled, forKey: "autoRecordEnabled") } }
    /// Normalized region (0…1) in top-left-origin coordinates of the captured frame.
    @Published var region: CGRect { didSet { save(region, "region") } }
    @Published var regionShape: RegionShape { didSet { save(regionShape, "regionShape") } }
    /// 0 = very insensitive, 1 = very sensitive.
    @Published var sensitivity: Double { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var startDelay: Double { didSet { d.set(startDelay, forKey: "startDelay") } }
    @Published var stopDelay: Double { didSet { d.set(stopDelay, forKey: "stopDelay") } }
    @Published var baseline: [Float]? { didSet { save(baseline, "baseline") } }

    /// Last picture area used for the VUER window.
    @Published var vuerCrop: CGRect? { didSet { save(vuerCrop, "vuerCrop") } }

    /// Folder / file name template, see `NamingScheme`.
    @Published var namingTemplate: String { didSet { d.set(namingTemplate, forKey: "namingTemplate") } }
    /// Labels written before scene, shot and take ("SC12A_SH03_TK07").
    @Published var sceneLabel: String { didSet { d.set(sceneLabel, forKey: "sceneLabel") } }
    @Published var shotLabel: String { didSet { d.set(shotLabel, forKey: "shotLabel") } }
    @Published var takeLabel: String { didSet { d.set(takeLabel, forKey: "takeLabel") } }

    /// Read the camera's timecode from the picture (OCR).
    @Published var timecodeEnabled: Bool { didSet { d.set(timecodeEnabled, forKey: "timecodeEnabled") } }
    /// Where the timecode is shown in the picture (normalized, top-left origin).
    @Published var timecodeRegion: CGRect { didSet { save(timecodeRegion, "timecodeRegion") } }

    /// Values used for the *next* clip.
    @Published var scene: String { didSet { d.set(scene, forKey: "scene") } }
    @Published var shot: Int { didSet { d.set(shot, forKey: "shot") } }
    @Published var take: Int { didSet { d.set(take, forKey: "take") } }

    @Published var skippedVersion: String? { didSet { d.set(skippedVersion, forKey: "skippedVersion") } }

    /// Customized shortcuts; actions missing here use their default.
    @Published var shortcuts: [ShortcutAction: ShortcutBinding] { didSet { save(shortcuts, "shortcuts") } }
    /// Source browser: show only the last take of each shot.
    @Published var browserLastTakesOnly: Bool { didSet { d.set(browserLastTakesOnly, forKey: "browserLastTakesOnly") } }
    /// File browser: take list folded away (⌃⌘S), the monitors get the whole width.
    @Published var browserSidebarHidden: Bool { didSet { d.set(browserSidebarHidden, forKey: "browserSidebarHidden") } }
    /// File browser: scenes / shots folded up in the take list (scene ID or "scene|shot").
    @Published var browserCollapsed: Set<String> { didSet { save(browserCollapsed, "browserCollapsed") } }
    /// Teradek network streams entered by hand (newest first).
    @Published var recentStreamAddresses: [String] { didSet { save(recentStreamAddresses, "recentStreamAddresses") } }

    private init() {
        let defaultFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kuhtake", isDirectory: true)
        workingFolder = d.string(forKey: "workingFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
        showNamingPrompt = d.object(forKey: "showNamingPrompt") as? Bool ?? true
        container = Self.load("container") ?? .mov
        codec = Self.load("codec") ?? .h264
        resolution = Self.load("resolution") ?? .native
        frameRate = Self.load("frameRate") ?? .fps25
        bitrateMbps = d.object(forKey: "bitrateMbps") as? Double ?? 20
        recordAudio = d.object(forKey: "recordAudio") as? Bool ?? true
        showCursor = d.object(forKey: "showCursor") as? Bool ?? false
        source = Self.load("source")
        autoRecordEnabled = d.bool(forKey: "autoRecordEnabled")
        region = Self.load("region") ?? CGRect(x: 0.85, y: 0.04, width: 0.1, height: 0.08)
        regionShape = Self.load("regionShape") ?? .rectangle
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 0.6
        startDelay = d.object(forKey: "startDelay") as? Double ?? 0.3
        stopDelay = d.object(forKey: "stopDelay") as? Double ?? 1.5
        baseline = Self.load("baseline")
        vuerCrop = Self.load("vuerCrop")
        namingTemplate = Self.migrateTemplate(d.string(forKey: "namingTemplate"), hasLabels: d.string(forKey: "sceneLabel") != nil)
        sceneLabel = d.string(forKey: "sceneLabel") ?? NamingScheme.Labels.standard.scene
        shotLabel = d.string(forKey: "shotLabel") ?? NamingScheme.Labels.standard.shot
        takeLabel = d.string(forKey: "takeLabel") ?? NamingScheme.Labels.standard.take
        timecodeEnabled = d.object(forKey: "timecodeEnabled") as? Bool ?? true
        timecodeRegion = Self.load("timecodeRegion") ?? CGRect(x: 0.38, y: 0.9, width: 0.24, height: 0.06)
        scene = d.string(forKey: "scene") ?? "1"
        shot = d.object(forKey: "shot") as? Int ?? 1
        take = d.object(forKey: "take") as? Int ?? 1
        skippedVersion = d.string(forKey: "skippedVersion")
        shortcuts = Self.load("shortcuts") ?? [:]
        browserLastTakesOnly = d.bool(forKey: "browserLastTakesOnly")
        browserCollapsed = Self.load("browserCollapsed") ?? []
        browserSidebarHidden = d.bool(forKey: "browserSidebarHidden")
        recentStreamAddresses = Self.load("recentStreamAddresses") ?? []
        // Store the migrated state once, so the migration never runs again.
        d.set(namingTemplate, forKey: "namingTemplate")
        d.set(sceneLabel, forKey: "sceneLabel")
        d.set(shotLabel, forKey: "shotLabel")
        d.set(takeLabel, forKey: "takeLabel")
    }

    /// Until 1.2.1 the labels were part of the template ("SC{szene}_SH{shot}_TK{take}"); now each placeholder
    /// carries its label, so "SC"/"SH"/"TK" right before a placeholder are removed once.
    private static func migrateTemplate(_ stored: String?, hasLabels: Bool) -> String {
        guard let stored else { return NamingScheme.defaultTemplate }
        guard !hasLabels else { return stored }
        var t = stored
        for (label, names) in [("SC", "szene|scene|sc"), ("SH", "shot|einstellung|sh"), ("TK", "take|tk")] {
            t = t.replacingOccurrences(of: "\(label)(\\{(?:\(names))(?::\\d+)?\\})", with: "$1",
                                       options: [.regularExpression, .caseInsensitive])
        }
        return t
    }

    func shortcut(for action: ShortcutAction) -> ShortcutBinding {
        shortcuts[action] ?? action.defaultBinding
    }

    /// ProRes only lives in QuickTime containers.
    var effectiveContainer: ContainerFormat { codec.isProRes ? .mov : container }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            d.set(data, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
