import Foundation
import os

/// Detailed, timestamped protocol log of the network stream (RTSP exchange, packet statistics, decoder events).
/// Kept in memory (last lines) for the diagnosis report and mirrored to the unified log.
final class StreamLog {
    static let shared = StreamLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 4000
    private let osLog = Logger(subsystem: "com.skyks030.kuhtake", category: "stream")
    /// Also print to stdout (command line self test / diagnosis).
    var echo = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String, _ tag: String = "stream") {
        let line = "\(Self.stamp.string(from: Date())) [\(tag)] \(message)"
        lock.withLock {
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
        osLog.debug("\(line, privacy: .public)")
        if echo { print(line) }
    }

    var text: String { lock.withLock { lines.joined(separator: "\n") } }

    func clear() { lock.withLock { lines = [] } }

    /// Classic hex dump: offset, hex bytes, ASCII.
    static func hexDump(_ data: Data, limit: Int = 256, indent: String = "    ") -> String {
        let bytes = [UInt8](data.prefix(limit))
        var out: [String] = []
        for row in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[row..<min(row + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            out.append(indent + String(format: "%04x  ", row) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        if data.count > limit { out.append(indent + "… (\(data.count) Bytes insgesamt)") }
        return out.joined(separator: "\n")
    }
}

/// What the user typed as Teradek source: an encoder address (found automatically) or an explicit stream URL.
enum StreamAddress: Equatable {
    /// IP / host name of the encoder: Kuhtake probes for an open stream (RTSP on known ports and paths).
    case auto(host: String)
    case rtsp(URL, preferUDP: Bool)
    /// MPEG-TS pushed to this Mac (encoder mode "MPEG-TS"/UDP, optionally RTP-wrapped); group = multicast address.
    case tsUDP(port: UInt16, group: String?)
    /// MPEG-TS from an encoder in TCP server mode.
    case tsTCP(host: String, port: UInt16)
    /// HTTP Live Streaming (encoder mode "HLS").
    case hls(URL)
    case srt(URL)
    /// Built-in test encoder (see `TeradekSimulator`).
    case simulator(Mode)

    enum Mode: String, CaseIterable, Identifiable {
        case rtsp, rtspUDP = "rtsp-udp", ts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rtsp: return "RTSP über TCP"
            case .rtspUDP: return "RTSP über UDP"
            case .ts: return "MPEG-TS über UDP"
            }
        }
        var address: String { "simulator://\(rawValue)" }
    }

    static func parse(_ raw: String) -> StreamAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("simulator") {
            let mode = Mode(rawValue: String(lower.dropFirst("simulator://".count))) ?? .rtsp
            return .simulator(mode)
        }
        if lower.hasPrefix("rtsp://") || lower.hasPrefix("rtsps://"), let url = URL(string: s) {
            return .rtsp(url, preferUDP: false)
        }
        if lower.hasPrefix("rtspu://"), let url = URL(string: "rtsp://" + s.dropFirst("rtspu://".count)) {
            return .rtsp(url, preferUDP: true)
        }
        if lower.hasPrefix("udp://") || lower.hasPrefix("rtp://") {
            // udp://@:5000, udp://:5000, udp://239.1.1.1:5000
            var rest = String(s.dropFirst(6))
            if rest.hasPrefix("@") { rest.removeFirst() }
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard let portText = parts.last, let port = UInt16(portText) else { return nil }
            let host = parts.count > 1 ? String(parts[0]) : ""
            return .tsUDP(port: port, group: host.isEmpty ? nil : host)
        }
        if lower.hasPrefix("tcp://") {
            let rest = s.dropFirst(6)
            let parts = rest.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            return .tsTCP(host: String(parts[0]), port: port)
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: s) { return .hls(url) }
        if lower.hasPrefix("srt://"), let url = URL(string: s) { return .srt(url) }
        if s.contains("://") { return nil }
        return .auto(host: s.hasSuffix(".") ? String(s.dropLast()) : s)
    }

    var description: String {
        switch self {
        case .auto(let host): return "Encoder \(host) (automatisch)"
        case .rtsp(let url, let udp): return "RTSP\(udp ? "/UDP" : "") \(url.redactingPassword)"
        case .tsUDP(let port, let group): return "MPEG-TS/UDP \(group ?? "*"):\(port)"
        case .tsTCP(let host, let port): return "MPEG-TS/TCP \(host):\(port)"
        case .hls(let url): return "HLS \(url.redactingPassword)"
        case .srt(let url): return "SRT \(url.absoluteString)"
        case .simulator(let mode): return "Simulator (\(mode.label))"
        }
    }
}

extension URL {
    /// The URL without its password (for logs and the UI).
    var redactingPassword: String {
        guard password != nil, var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return absoluteString }
        c.password = "•••"
        return c.string ?? absoluteString
    }
}
