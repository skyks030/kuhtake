import CryptoKit
import Darwin
import Foundation
import Network

// MARK: - RTSP messages

struct RTSPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]   // lower-cased names
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var text: String {
        var s = "RTSP/1.0 \(status) \(reason)\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if !body.isEmpty { s += "\n\n" + (String(data: body, encoding: .utf8) ?? StreamLog.hexDump(body)) }
        return s
    }
}

/// Incremental parser for RTSP text messages and interleaved binary frames (`$` channel length data).
struct RTSPStreamParser {
    enum Item {
        case response(RTSPResponse)
        case request(method: String, uri: String, headers: [String: String], body: Data)
        case interleaved(channel: UInt8, data: Data)
    }

    private var buffer = Data()
    private(set) var skippedBytes = 0

    mutating func append(_ d: Data) { buffer.append(d) }

    mutating func next() -> Item? {
        while !buffer.isEmpty {
            let first = buffer[buffer.startIndex]
            if first == 0x24 {   // '$'
                guard buffer.count >= 4 else { return nil }
                let b = buffer.startIndex
                let channel = buffer[b + 1]
                let length = Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
                guard buffer.count >= 4 + length else { return nil }
                let payload = buffer.subdata(in: (b + 4)..<(b + 4 + length))
                buffer.removeSubrange(b..<(b + 4 + length))
                return .interleaved(channel: channel, data: payload)
            }
            if Self.startsWithText(buffer) {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 64 * 1024 { buffer.removeAll() }
                    return nil
                }
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let startLine = lines.removeFirst()
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[name] = headers[name].map { $0 + ", " + value } ?? value
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = end.upperBound
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
                let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: length))
                buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))
                let parts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
                if startLine.hasPrefix("RTSP/") {
                    return .response(RTSPResponse(status: Int(parts.count > 1 ? parts[1] : "") ?? 0,
                                                  reason: parts.count > 2 ? parts[2] : "", headers: headers, body: body))
                }
                return .request(method: parts.first ?? "", uri: parts.count > 1 ? parts[1] : "", headers: headers, body: body)
            }
            // Garbage: skip to the next '$' or text start.
            buffer.removeFirst()
            skippedBytes += 1
        }
        return nil
    }

    private static func startsWithText(_ b: Data) -> Bool {
        let prefix = String(decoding: b.prefix(8), as: UTF8.self)
        let known = ["RTSP/", "OPTIONS", "DESCRIBE", "SETUP", "PLAY", "PAUSE", "TEARDOWN", "GET_PARA", "SET_PARA", "ANNOUNCE", "RECORD"]
        // A message start that hasn't fully arrived yet counts, too.
        return known.contains { prefix.hasPrefix($0) || (prefix.count < $0.count && $0.hasPrefix(prefix)) }
    }
}

// MARK: - SDP

struct SDPMedia {
    var type: String                 // video / audio
    var payloadType: Int
    var encoding: String             // H264, H265, MPEG4-GENERIC …
    var clockRate: Int
    var channels: Int?
    var fmtp: [String: String] = [:]
    var control: String?
}

struct SDP {
    var sessionControl: String?
    var media: [SDPMedia] = []
    var raw: String

    init(_ text: String) {
        raw = text
        var current: SDPMedia?
        var rtpmaps: [Int: (String, Int, Int?)] = [:]
        var fmtps: [Int: [String: String]] = [:]
        func finish() {
            guard var m = current else { return }
            if let map = rtpmaps[m.payloadType] { m.encoding = map.0.uppercased(); m.clockRate = map.1; m.channels = map.2 }
            else if m.payloadType == 33 { m.encoding = "MP2T"; m.clockRate = 90000 }
            else if m.payloadType == 26 { m.encoding = "JPEG"; m.clockRate = 90000 }
            m.fmtp = fmtps[m.payloadType] ?? [:]
            media.append(m)
            rtpmaps = [:]
            fmtps = [:]
        }
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("m=") {
                finish()
                let parts = l.dropFirst(2).split(separator: " ")
                current = SDPMedia(type: parts.first.map(String.init) ?? "", payloadType: parts.count > 3 ? Int(parts[3]) ?? -1 : -1,
                                   encoding: "", clockRate: 90000)
            } else if l.hasPrefix("a=rtpmap:") {
                let rest = l.dropFirst("a=rtpmap:".count)
                let parts = rest.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let pt = Int(parts[0]) else { continue }
                let enc = parts[1].split(separator: "/")
                rtpmaps[pt] = (String(enc[0]), enc.count > 1 ? Int(enc[1]) ?? 90000 : 90000, enc.count > 2 ? Int(enc[2]) : nil)
            } else if l.hasPrefix("a=fmtp:") {
                let rest = l.dropFirst("a=fmtp:".count)
                let parts = rest.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let pt = Int(parts[0]) else { continue }
                var params: [String: String] = [:]
                for p in parts[1].split(separator: ";") {
                    let kv = p.split(separator: "=", maxSplits: 1)
                    let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                    params[key] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
                }
                fmtps[pt] = params
            } else if l.hasPrefix("a=control:") {
                let value = String(l.dropFirst("a=control:".count))
                if current == nil { sessionControl = value } else { current?.control = value }
            }
        }
        finish()
    }

    var video: SDPMedia? { media.first { $0.type == "video" } }
    var audio: SDPMedia? { media.first { $0.type == "audio" } }
}

// MARK: - Authentication

/// Basic and Digest (RFC 2617, MD5) for RTSP and HTTP.
struct RTSPAuthenticator {
    let user: String
    let password: String
    let challenge: String

    func header(method: String, uri: String) -> String? {
        let lower = challenge.lowercased()
        if lower.hasPrefix("basic") {
            return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        guard lower.hasPrefix("digest") else { return nil }
        let params = Self.params(String(challenge.dropFirst(6)))
        let realm = params["realm"] ?? ""
        let nonce = params["nonce"] ?? ""
        let ha1 = Self.md5("\(user):\(realm):\(password)")
        let ha2 = Self.md5("\(method):\(uri)")
        var h = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
        if let qop = params["qop"], qop.contains("auth") {
            let cnonce = String(UUID().uuidString.prefix(8)).lowercased()
            let response = Self.md5("\(ha1):\(nonce):00000001:\(cnonce):auth:\(ha2)")
            h += ", qop=auth, nc=00000001, cnonce=\"\(cnonce)\", response=\"\(response)\""
        } else {
            h += ", response=\"\(Self.md5("\(ha1):\(nonce):\(ha2)"))\""
        }
        if let opaque = params["opaque"] { h += ", opaque=\"\(opaque)\"" }
        return h
    }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func params(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))"#)
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s) else { continue }
            let v = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? Range(m.range(at: 3), in: s).map { String(s[$0]) } ?? ""
            out[String(s[k]).lowercased()] = v
        }
        return out
    }
}

// MARK: - RTP

struct RTPPacket {
    let payloadType: Int
    let marker: Bool
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    init?(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let padding = b[0] & 0x20 != 0
        let hasExtension = b[0] & 0x10 != 0
        let csrc = Int(b[0] & 0x0f)
        marker = b[1] & 0x80 != 0
        payloadType = Int(b[1] & 0x7f)
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        var offset = 12 + 4 * csrc
        if hasExtension {
            guard b.count >= offset + 4 else { return nil }
            offset += 4 + 4 * (Int(b[offset + 2]) << 8 | Int(b[offset + 3]))
        }
        var end = b.count
        if padding, let last = b.last { end -= Int(last) }
        guard end >= offset else { return nil }
        payload = Data(b[offset..<end])
    }

    static func make(payloadType: Int, marker: Bool, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) -> Data {
        var d = Data(capacity: 12 + payload.count)
        d.append(0x80)
        d.append(UInt8(payloadType & 0x7f) | (marker ? 0x80 : 0))
        d.append(UInt8(sequence >> 8)); d.append(UInt8(sequence & 0xff))
        for shift in [24, 16, 8, 0] { d.append(UInt8((timestamp >> UInt32(shift)) & 0xff)) }
        for shift in [24, 16, 8, 0] { d.append(UInt8((ssrc >> UInt32(shift)) & 0xff)) }
        d.append(payload)
        return d
    }
}

/// 32-bit RTP timestamps → continuous seconds.
struct TimestampUnwrapper {
    private var last: UInt32?
    private var extended: Int64 = 0

    mutating func seconds(_ ts: UInt32, clockRate: Int) -> Double {
        if let last { extended += Int64(Int32(bitPattern: ts &- last)) } else { extended = Int64(ts) }
        last = ts
        return Double(extended) / Double(max(clockRate, 1))
    }
}

/// RTP payload → access units for H.264 (RFC 6184) and HEVC (RFC 7798).
final class VideoDepacketizer {
    let codec: StreamVideoCodec
    private var nals: [Data] = []
    private var fragment: Data?
    private var currentTimestamp: UInt32?
    private var lastSequence: UInt16?
    private var broken = false
    private(set) var lostPackets = 0
    private(set) var unsupportedPackets = 0

    init(codec: StreamVideoCodec) { self.codec = codec }

    /// Returns a complete picture (NAL units + RTP timestamp) when one is finished.
    func push(_ p: RTPPacket) -> (nals: [Data], timestamp: UInt32)? {
        var done: (nals: [Data], timestamp: UInt32)?
        if let last = lastSequence, p.sequence != last &+ 1 {
            lostPackets += Int(p.sequence &- last &- 1)
            broken = true
            fragment = nil
        }
        lastSequence = p.sequence
        if let ts = currentTimestamp, ts != p.timestamp {
            done = flush()
        }
        currentTimestamp = p.timestamp
        let b = [UInt8](p.payload)
        if !b.isEmpty {
            codec == .h264 ? h264(b) : hevc(b)
        }
        if p.marker, let f = flush() { done = f }
        return done
    }

    private func flush() -> (nals: [Data], timestamp: UInt32)? {
        defer { nals = []; fragment = nil; broken = false }
        guard let ts = currentTimestamp, !nals.isEmpty, !broken else { return nil }
        return (nals, ts)
    }

    private func h264(_ b: [UInt8]) {
        let type = Int(b[0] & 0x1f)
        switch type {
        case 1...23:
            nals.append(Data(b))
        case 24:   // STAP-A
            var i = 1
            while i + 2 <= b.count {
                let size = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard size > 0, i + size <= b.count else { break }
                nals.append(Data(b[i..<(i + size)]))
                i += size
            }
        case 28:   // FU-A
            guard b.count > 2 else { return }
            let start = b[1] & 0x80 != 0, end = b[1] & 0x40 != 0
            if start {
                fragment = Data([(b[0] & 0xe0) | (b[1] & 0x1f)]) + Data(b[2...])
            } else if fragment != nil {
                fragment!.append(contentsOf: b[2...])
            }
            if end, let f = fragment { nals.append(f); fragment = nil }
        default:
            unsupportedPackets += 1
        }
    }

    private func hevc(_ b: [UInt8]) {
        guard b.count > 2 else { return }
        let type = Int((b[0] >> 1) & 0x3f)
        switch type {
        case 48:   // aggregation packet
            var i = 2
            while i + 2 <= b.count {
                let size = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard size > 0, i + size <= b.count else { break }
                nals.append(Data(b[i..<(i + size)]))
                i += size
            }
        case 49:   // fragmentation unit
            guard b.count > 3 else { return }
            let fu = b[2]
            let start = fu & 0x80 != 0, end = fu & 0x40 != 0
            if start {
                let h0 = (b[0] & 0x81) | ((fu & 0x3f) << 1)
                fragment = Data([h0, b[1]]) + Data(b[3...])
            } else if fragment != nil {
                fragment!.append(contentsOf: b[3...])
            }
            if end, let f = fragment { nals.append(f); fragment = nil }
        case 50:
            unsupportedPackets += 1
        default:
            nals.append(Data(b))
        }
    }
}

/// RTP mpeg4-generic (RFC 3640, AAC-hbr) → raw AAC frames.
final class AACDepacketizer {
    private let sizeLength: Int
    private let indexLength: Int
    private var pending = Data()

    init(fmtp: [String: String]) {
        sizeLength = Int(fmtp["sizelength"] ?? "13") ?? 13
        indexLength = Int(fmtp["indexlength"] ?? "3") ?? 3
    }

    func push(_ p: RTPPacket) -> [(Data, UInt32)] {
        let b = [UInt8](p.payload)
        guard b.count >= 2 else { return [] }
        let headerBits = Int(b[0]) << 8 | Int(b[1])
        let headerBytes = (headerBits + 7) / 8
        guard b.count >= 2 + headerBytes else { return [] }
        var sizes: [Int] = []
        var bit = 0
        let perHeader = sizeLength + indexLength
        func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = b[2 + bit / 8]
                v = v << 1 | Int((byte >> (7 - UInt8(bit % 8))) & 1)
                bit += 1
            }
            return v
        }
        while perHeader > 0, bit + perHeader <= headerBits {
            sizes.append(read(sizeLength))
            _ = read(indexLength)
        }
        var offset = 2 + headerBytes
        var frames: [(Data, UInt32)] = []
        // One AU spread over several packets (rare for AAC).
        if sizes.count == 1, offset + sizes[0] > b.count {
            pending.append(contentsOf: b[offset...])
            if p.marker || pending.count >= sizes[0] {
                frames.append((pending.prefix(sizes[0]), p.timestamp))
                pending = Data()
            }
            return frames
        }
        pending = Data()
        for (i, size) in sizes.enumerated() {
            guard offset + size <= b.count else { break }
            frames.append((Data(b[offset..<(offset + size)]), p.timestamp &+ UInt32(i * 1024)))
            offset += size
        }
        return frames
    }
}

// MARK: - UDP socket

/// Plain UDP receiver (RTP over UDP, MPEG-TS over UDP, multicast) on its own dispatch source.
final class UDPReceiver {
    let port: UInt16
    private let fd: Int32
    private let source: DispatchSourceRead
    private(set) var lastSender: String?

    /// port 0 = any free port. `group`: multicast address to join.
    init(port: UInt16, group: String? = nil, queue: DispatchQueue, handler: @escaping (Data, String) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw StreamError.socket("socket() \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw StreamError.socket("UDP-Port \(port) kann nicht geöffnet werden: \(msg)")
        }
        if let group {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(group)
            mreq.imr_interface.s_addr = INADDR_ANY
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) != 0 {
                StreamLog.shared.log("Multicast-Gruppe \(group) konnte nicht beigetreten werden: \(String(cString: strerror(errno)))", "udp")
            }
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: actual.sin_port)
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        source.setEventHandler { [weak self] in
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { return }
            let sender = String(cString: inet_ntoa(from.sin_addr)) + ":\(UInt16(bigEndian: from.sin_port))"
            self?.lastSender = sender
            handler(Data(buffer[0..<n]), sender)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func send(_ data: Data, to host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func cancel() { source.cancel() }
}

enum StreamError: LocalizedError {
    case socket(String)
    case rtsp(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .socket(let s), .rtsp(let s), .unsupported(let s): return s
        }
    }
}

// MARK: - Client

/// RTSP client: OPTIONS → DESCRIBE (with Basic/Digest auth) → SETUP (RTP over TCP interleaved, or UDP) → PLAY,
/// keep-alive, and RTP → access units → `MediaOutput`.
final class RTSPClient {
    struct Stats {
        var rtpPackets = 0
        var rtpBytes = 0
        var videoUnits = 0
        var audioFrames = 0
        var lostPackets = 0
        var lastPacketAt: Double = 0
    }

    let url: URL
    let useUDP: Bool
    private let queue: DispatchQueue
    private let output: StreamMediaOutput
    private let log = StreamLog.shared
    private var connection: NWConnection?
    private var parser = RTSPStreamParser()
    private var cseq = 0
    private var pending: [Int: (RTSPResponse) -> Void] = [:]
    private var session: String?
    private var sessionTimeout = 60
    private var authenticator: RTSPAuthenticator?
    private var publicMethods: Set<String> = []
    private var keepAlive: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var stopped = false
    private var udpReceivers: [UDPReceiver] = []

    private var video: (media: SDPMedia, depacketizer: VideoDepacketizer, channel: Int)?
    private var audio: (media: SDPMedia, depacketizer: AACDepacketizer, channel: Int)?
    private var videoClock = TimestampUnwrapper()
    private var audioClock = TimestampUnwrapper()
    private(set) var stats = Stats()
    private(set) var sdp: SDP?
    /// The TCP connection to the encoder came up (tells "nothing listens there" apart from "refused the stream").
    private(set) var connected = false
    /// Status of the last RTSP response.
    private(set) var lastStatus = 0

    /// Called once on the client queue: nil = playing, otherwise the reason it stopped / failed.
    var onPlaying: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(url: URL, useUDP: Bool, queue: DispatchQueue, output: StreamMediaOutput) {
        self.url = url
        self.useUDP = useUDP
        self.queue = queue
        self.output = output
    }

    /// The URL as sent in requests (without user/password).
    private var requestURL: String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.user = nil
        c.password = nil
        if c.port == nil { c.port = 554 }
        return c.string ?? url.absoluteString
    }

    func start() {
        guard let host = url.host else { fail("Ungültige Adresse: \(url.absoluteString)"); return }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) ?? 554
        log.log("Verbinde mit \(host):\(port) (\(useUDP ? "RTP über UDP" : "RTP über TCP interleaved")) …", "rtsp")
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 5
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.connected = true
                self.log.log("TCP verbunden (\(c.currentPath?.localEndpoint.map { "\($0)" } ?? "?") → \(host):\(port))", "rtsp")
                self.receive()
                self.options()
            case .waiting(let e):
                self.fail("Verbindung zu \(host):\(port) wartet: \(e.localizedDescription)")
            case .failed(let e):
                self.fail("Verbindung zu \(host):\(port) fehlgeschlagen: \(e.localizedDescription)")
            default: break
            }
        }
        c.start(queue: queue)
    }

    func stop() {
        guard !stopped else { return }
        if session != nil { send("TEARDOWN", uri: requestURL) { _ in } }
        stopped = true
        keepAlive?.cancel()
        watchdog?.cancel()
        udpReceivers.forEach { $0.cancel() }
        udpReceivers = []
        let c = connection
        queue.asyncAfter(deadline: .now() + 0.2) { c?.cancel() }
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        log.log("Fehler: \(reason)", "rtsp")
        stop()
        onFailure?(reason)
        onFailure = nil
    }

    // MARK: Requests

    private func send(_ method: String, uri: String, headers: [String: String] = [:], retried: Bool = false,
                      completion: @escaping (RTSPResponse) -> Void) {
        guard let connection else { return }
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Kuhtake/\(Self.version)"]
        if let session { lines.append("Session: \(session)") }
        if let auth = authenticator?.header(method: method, uri: uri) { lines.append("Authorization: \(auth)") }
        for (k, v) in headers { lines.append("\(k): \(v)") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        log.log("→ \(method) \(uri)\n" + lines.dropFirst().map { "    " + ($0.hasPrefix("Authorization") ? "Authorization: •••" : $0) }.joined(separator: "\n"), "rtsp")
        pending[cseq] = { [weak self] response in
            guard let self else { return }
            if response.status == 401, !retried, let challenge = response.header("www-authenticate") {
                guard let user = self.url.user else {
                    self.fail("Der Encoder verlangt Benutzername und Passwort (401). Adresse als rtsp://benutzer:passwort@… eingeben.")
                    return
                }
                // Prefer Digest when several schemes are offered.
                let schemes = challenge.components(separatedBy: ", Digest").count > 1 ? "Digest" + challenge.components(separatedBy: ", Digest")[1] : challenge
                self.authenticator = RTSPAuthenticator(user: user.removingPercentEncoding ?? user,
                                                       password: self.url.password?.removingPercentEncoding ?? "", challenge: schemes)
                self.send(method, uri: uri, headers: headers, retried: true, completion: completion)
                return
            }
            completion(response)
        }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] e in
            if let e { self?.fail("Senden fehlgeschlagen: \(e.localizedDescription)") }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                while let item = self.parser.next() { self.handle(item) }
            }
            if let error { self.fail("Empfang: \(error.localizedDescription)"); return }
            if complete { self.fail("Der Encoder hat die Verbindung geschlossen"); return }
            self.receive()
        }
    }

    private func handle(_ item: RTSPStreamParser.Item) {
        switch item {
        case .response(let r):
            log.log("← \(r.status) \(r.reason)\n" + r.text.split(separator: "\n").dropFirst().map { "    " + $0 }.joined(separator: "\n"), "rtsp")
            lastStatus = r.status
            let seq = Int(r.header("cseq") ?? "") ?? -1
            if let handler = pending.removeValue(forKey: seq) { handler(r) }
        case .request(let method, _, let headers, _):
            // Server → client requests (e.g. GET_PARAMETER keep-alive or ANNOUNCE): answer politely.
            log.log("← Anfrage vom Encoder: \(method)", "rtsp")
            let reply = "RTSP/1.0 200 OK\r\nCSeq: \(headers["cseq"] ?? "0")\r\n\r\n"
            connection?.send(content: Data(reply.utf8), completion: .idempotent)
        case .interleaved(let channel, let data):
            handleRTP(data, channel: Int(channel))
        }
    }

    // MARK: Sequence

    private func options() {
        send("OPTIONS", uri: requestURL) { [weak self] r in
            guard let self else { return }
            self.publicMethods = Set((r.header("public") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
            // Some encoders answer OPTIONS with 401/404 but DESCRIBE fine – carry on regardless.
            self.describe()
        }
    }

    private func describe() {
        send("DESCRIBE", uri: requestURL, headers: ["Accept": "application/sdp"]) { [weak self] r in
            guard let self else { return }
            guard r.status == 200 else {
                self.fail(r.status == 401 ? "Benutzername oder Passwort falsch (401)"
                          : r.status == 404 ? "Stream-Pfad nicht gefunden (404): \(self.url.path)"
                          : "DESCRIBE abgelehnt: \(r.status) \(r.reason)")
                return
            }
            let sdp = SDP(String(decoding: r.body, as: UTF8.self))
            self.sdp = sdp
            let base = r.header("content-base") ?? r.header("content-location") ?? self.requestURL
            self.log.log("SDP: \(sdp.media.map { "\($0.type) \($0.encoding)/\($0.clockRate) PT \($0.payloadType) control=\($0.control ?? "-") fmtp=\($0.fmtp)" }.joined(separator: " | "))", "rtsp")
            var steps: [(SDPMedia, Int)] = []
            if let v = sdp.video {
                switch v.encoding {
                case "H264":
                    self.video = (v, VideoDepacketizer(codec: .h264), 0)
                    let sets = (v.fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
                    if !sets.isEmpty { self.output.parameterSets(sets, codec: .h264) }
                case "H265", "HEVC":
                    self.video = (v, VideoDepacketizer(codec: .hevc), 0)
                    let sets = ["sprop-vps", "sprop-sps", "sprop-pps"].compactMap { v.fmtp[$0] }.compactMap { Data(base64Encoded: $0) }
                    if !sets.isEmpty { self.output.parameterSets(sets, codec: .hevc) }
                default:
                    self.fail("Videoformat \(v.encoding) wird nicht unterstützt (nur H.264 / HEVC)")
                    return
                }
                steps.append((v, 0))
            } else {
                self.fail("Der Stream enthält kein Video")
                return
            }
            if let a = sdp.audio {
                if a.encoding == "MPEG4-GENERIC", let config = AACConfig.fromHex(a.fmtp["config"] ?? "") {
                    self.audio = (a, AACDepacketizer(fmtp: a.fmtp), 2)
                    self.output.audioConfig(config)
                    steps.append((a, 2))
                } else {
                    self.log.log("Tonformat \(a.encoding) wird (noch) nicht unterstützt – nur Bild", "rtsp")
                }
            }
            self.setup(steps, base: base, sessionControl: sdp.sessionControl)
        }
    }

    private func controlURL(_ control: String?, base: String) -> String {
        guard let control, control != "*" else { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    private func setup(_ steps: [(SDPMedia, Int)], base: String, sessionControl: String?) {
        guard let (media, channel) = steps.first else {
            play(uri: sessionControl.map { controlURL($0, base: base) } ?? base)
            return
        }
        var transport = "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)"
        if useUDP {
            do {
                let rtp = try UDPReceiver(port: 0, queue: queue) { [weak self] data, _ in self?.handleRTP(data, channel: channel) }
                udpReceivers.append(rtp)
                transport = "RTP/AVP;unicast;client_port=\(rtp.port)-\(rtp.port + 1)"
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        send("SETUP", uri: controlURL(media.control, base: base), headers: ["Transport": transport]) { [weak self] r in
            guard let self else { return }
            guard r.status == 200 else {
                self.fail(r.status == 461 ? "Der Encoder unterstützt \(self.useUDP ? "UDP" : "TCP") als Transport nicht (461)"
                          : "SETUP abgelehnt: \(r.status) \(r.reason)")
                return
            }
            if let s = r.header("session") {
                let parts = s.split(separator: ";")
                self.session = parts.first.map { $0.trimmingCharacters(in: .whitespaces) }
                for p in parts.dropFirst() where p.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("timeout=") {
                    self.sessionTimeout = Int(p.split(separator: "=").last ?? "") ?? 60
                }
            }
            // The server may pick other interleaved channels.
            if let t = r.header("transport"), let range = t.range(of: "interleaved=") {
                let value = t[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
                if let first = Int(value.split(separator: "-").first ?? "") {
                    if media.type == "video" { self.video?.channel = first } else { self.audio?.channel = first }
                }
            }
            self.setup(Array(steps.dropFirst()), base: base, sessionControl: sessionControl)
        }
    }

    private func play(uri: String) {
        send("PLAY", uri: uri, headers: ["Range": "npt=0.000-"]) { [weak self] r in
            guard let self else { return }
            guard r.status == 200 else { self.fail("PLAY abgelehnt: \(r.status) \(r.reason)"); return }
            self.log.log("Wiedergabe läuft (Session \(self.session ?? "-"), Timeout \(self.sessionTimeout) s)", "rtsp")
            self.stats.lastPacketAt = StreamClock.hostNow
            self.startTimers()
            self.onPlaying?()
            self.onPlaying = nil
        }
    }

    private func startTimers() {
        let interval = Double(max(10, sessionTimeout)) * 0.5
        let k = DispatchSource.makeTimerSource(queue: queue)
        k.schedule(deadline: .now() + interval, repeating: interval)
        k.setEventHandler { [weak self] in
            guard let self else { return }
            let method = self.publicMethods.contains("GET_PARAMETER") || self.publicMethods.isEmpty ? "GET_PARAMETER" : "OPTIONS"
            self.send(method, uri: self.requestURL) { _ in }
        }
        k.resume()
        keepAlive = k
        let w = DispatchSource.makeTimerSource(queue: queue)
        w.schedule(deadline: .now() + 1, repeating: 1)
        w.setEventHandler { [weak self] in
            guard let self else { return }
            if StreamClock.hostNow - self.stats.lastPacketAt > 5 {
                self.fail(self.stats.rtpPackets == 0
                          ? "Nach PLAY kommen keine Daten an (\(self.useUDP ? "UDP-Pakete evtl. von Firewall blockiert" : "TCP"))"
                          : "Seit 5 Sekunden keine Daten mehr")
            }
        }
        w.resume()
        watchdog = w
    }

    // MARK: RTP

    private func handleRTP(_ data: Data, channel: Int) {
        if channel % 2 == 1 { return }   // RTCP
        guard let p = RTPPacket(data) else { return }
        stats.rtpPackets += 1
        stats.rtpBytes += data.count
        stats.lastPacketAt = StreamClock.hostNow
        if stats.rtpPackets == 1 {
            log.log("Erstes RTP-Paket: Kanal \(channel), PT \(p.payloadType), SSRC \(String(format: "%08x", p.ssrc)), \(data.count) Bytes\n" + StreamLog.hexDump(data, limit: 48), "rtp")
        }
        if let v = video, channel == v.channel {
            if let unit = v.depacketizer.push(p) {
                stats.videoUnits += 1
                stats.lostPackets = v.depacketizer.lostPackets
                output.video(unit.nals, codec: v.depacketizer.codec, time: videoClock.seconds(unit.timestamp, clockRate: v.media.clockRate))
            }
        } else if let a = audio, channel == a.channel {
            for (frame, ts) in a.depacketizer.push(p) {
                stats.audioFrames += 1
                output.aac(frame, time: audioClock.seconds(ts, clockRate: a.media.clockRate))
            }
        }
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

/// Where receivers deliver: parameter sets, pictures and audio frames on the stream's own clocks.
protocol StreamMediaOutput: AnyObject {
    func parameterSets(_ nals: [Data], codec: StreamVideoCodec)
    func video(_ nals: [Data], codec: StreamVideoCodec, time: Double)
    func audioConfig(_ config: AACConfig)
    func aac(_ frame: Data, time: Double)
}
