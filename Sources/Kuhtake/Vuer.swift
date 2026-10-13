import AppKit
import CoreVideo
import Foundation

/// Teradek's monitoring app (VUER / Vuer HDR) on the Mac.
///
/// Serv Pro, Serv 4K, Bolt and Cube encoders talk to VUER over Teradek's own streaming protocol (Bonjour service
/// `_tdstream._tcp`, built on SRT); Teradek doesn't document it and the Serv Pro offers no RTSP/HLS alternative.
/// Kuhtake therefore records VUER's decoded picture: the app's window is found by its bundle ID (also after VUER
/// restarts), captured at native resolution via ScreenCaptureKit, and cut down to the video area.
struct VuerApp: Equatable {
    let bundleID: String
    let name: String

    static let hdr = VuerApp(bundleID: "com.teradek.vuerMac", name: "Vuer HDR")

    /// Every Teradek VUER variant shares this prefix.
    static func isVuer(bundleID: String?, appName: String?) -> Bool {
        if let id = bundleID?.lowercased(), id.hasPrefix("com.teradek.vuer") { return true }
        return appName?.lowercased().contains("vuer") == true
    }

    var installedURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { installedURL != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    func launch() {
        guard let url = installedURL else {
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id1514874968")!)
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}

// MARK: - Teradek encoders on the network

/// Lists Teradek encoders on the local network (the same Bonjour services VUER browses), so the source picker
/// can show whether a Serv Pro & co. is reachable at all before looking at VUER.
final class TeradekBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = TeradekBrowser()

    struct Encoder: Identifiable, Hashable {
        var id: String { name }
        let name: String
        var host: String?
        var port: Int?
        var services: Set<String>
        /// Web UI of the encoder (its IP / host name).
        var webURL: URL? { host.flatMap { URL(string: "http://\($0.hasSuffix(".") ? String($0.dropLast()) : $0)") } }
    }

    @Published private(set) var encoders: [Encoder] = []
    @Published private(set) var isSearching = false

    private static let serviceTypes = ["_tdstream._tcp.", "_apollo._tcp."]
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var found: [String: Encoder] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        isSearching = true
        for type in Self.serviceTypes {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers = []
        services.forEach { $0.stop() }
        services = []
        isSearching = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        var e = found[service.name] ?? Encoder(name: service.name, services: [])
        e.services.insert(service.type)
        found[service.name] = e
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
        if !moreComing { publish() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if var e = found[service.name] {
            e.services.remove(service.type)
            found[service.name] = e.services.isEmpty ? nil : e
        }
        services.removeAll { $0 == service }
        if !moreComing { publish() }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard var e = found[sender.name] else { return }
        e.host = sender.hostName ?? e.host
        if sender.type == "_tdstream._tcp." { e.port = sender.port }
        found[sender.name] = e
        publish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if browsers.allSatisfy({ $0 === browser }) { isSearching = false }
    }

    private func publish() {
        let list = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { self.encoders = list }
    }
}

// MARK: - Finding the video area

enum VideoAreaDetector {
    /// Cuts uniform borders (window background, black bars, plain toolbars) off the captured window and returns
    /// the remaining picture area, normalized with top-left origin. Close to 16:9 it snaps to exactly 16:9.
    static func detect(in pb: CVPixelBuffer) -> CGRect? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard width > 32, height > 32 else { return nil }

        func luma(_ x: Int, _ y: Int) -> Int {
            let p = base + y * bpr + x * 4
            return (Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8
        }
        // A line belongs to the border if nearly all of its samples have the same brightness as its first sample
        // or are dark UI (icons on a toolbar are few pixels, so the share is what counts).
        func isUniform(samples: [Int]) -> Bool {
            guard let ref = samples.sorted().dropFirst(samples.count / 2).first else { return true }
            let close = samples.filter { abs($0 - ref) <= 10 }.count
            return Double(close) / Double(samples.count) >= 0.9
        }
        let steps = 96
        func row(_ y: Int) -> [Int] { (0..<steps).map { luma($0 * (width - 1) / (steps - 1), y) } }
        func column(_ x: Int) -> [Int] { (0..<steps).map { luma(x, $0 * (height - 1) / (steps - 1)) } }

        var top = 0, bottom = height - 1, left = 0, right = width - 1
        while top < bottom, isUniform(samples: row(top)) { top += 1 }
        while bottom > top, isUniform(samples: row(bottom)) { bottom -= 1 }
        while left < right, isUniform(samples: column(left)) { left += 1 }
        while right > left, isUniform(samples: column(right)) { right -= 1 }
        let w = right - left + 1, h = bottom - top + 1
        guard w > width / 5, h > height / 5 else { return nil }

        var r = CGRect(x: CGFloat(left) / CGFloat(width), y: CGFloat(top) / CGFloat(height),
                       width: CGFloat(w) / CGFloat(width), height: CGFloat(h) / CGFloat(height))
        // Snap to 16:9 when nearly there (a toolbar row that was not uniform enough).
        let aspect = CGFloat(w) / CGFloat(h)
        let target: CGFloat = 16 / 9
        if abs(aspect - target) / target < 0.1 {
            if aspect > target {
                let newW = CGFloat(h) * target
                r.origin.x += (CGFloat(w) - newW) / 2 / CGFloat(width)
                r.size.width = newW / CGFloat(width)
            } else {
                let newH = CGFloat(w) / target
                r.origin.y += (CGFloat(h) - newH) / 2 / CGFloat(height)
                r.size.height = newH / CGFloat(height)
            }
        }
        return r
    }
}
