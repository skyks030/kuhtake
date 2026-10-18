import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Network

/// Built-in test encoder: a moving test pattern with timecode and a 1 kHz beep, sent the way a Teradek encoder would –
/// as an RTSP server on 127.0.0.1 (RTP over TCP interleaved or UDP) or as MPEG-TS over UDP. For trying the network
/// input without hardware (`simulator://rtsp`, `simulator://rtsp-udp`, `simulator://ts`, and `--stream-selftest`).
final class TeradekSimulator {
    static let width = 1280, height = 720, fps = 25
    static let sampleRate = 48_000

    private let queue = DispatchQueue(label: "kuhtake.simulator", qos: .userInitiated)
    private let log = StreamLog.shared
    private var video: H264TestEncoder?
    private var audio: AACTestEncoder?
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var audioSamples = 0
    private var audioPackets = 0
    private var firstFrameWaiters: [() -> Void] = []
    private var hasFirstFrame = false

    // RTSP server
    private var listener: NWListener?
    private var rtspPort: UInt16?
    private var portWaiters: [(Result<UInt16, Error>) -> Void] = []
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var udpOut: UDPReceiver?

    // MPEG-TS
    private var tsPort: UInt16?
    private let muxer = TSMuxer()
    private var tsPending: [Data] = []

    private static let videoSSRC: UInt32 = 0x4b55_4854, audioSSRC: UInt32 = 0x4b55_4841
    private static let sessionID = "4B554854"

    private final class Session {
        let connection: NWConnection
        var parser = RTSPStreamParser()
        var playing = false
        /// Per track (0 = video, 1 = audio): interleaved channel, or the client's UDP port.
        var channel: [Int: UInt8] = [:]
        var udpPort: [Int: UInt16] = [:]
        var sequence: [Int: UInt16] = [0: 0, 1: 0]
        init(_ c: NWConnection) { connection = c }
    }

    // MARK: Start / stop

    /// RTSP server mode; `completion` gets the port once the first picture is encoded (so DESCRIBE has SPS/PPS).
    func startRTSP(completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async {
            if let port = self.rtspPort { completion(.success(port)); return }
            self.portWaiters.append(completion)
            guard self.listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = l.port?.rawValue else { return }
                        self.log.log("Test-Encoder: RTSP-Server auf rtsp://127.0.0.1:\(port)/stream1", "sim")
                        self.whenFirstFrame {
                            self.rtspPort = port
                            self.portWaiters.forEach { $0(.success(port)) }
                            self.portWaiters = []
                        }
                    case .failed(let e):
                        self.portWaiters.forEach { $0(.failure(e)) }
                        self.portWaiters = []
                        self.listener = nil
                    default:
                        break
                    }
                }
                l.start(queue: self.queue)
                self.listener = l
                self.udpOut = try UDPReceiver(port: 0, queue: self.queue) { _, _ in }   // also used for sending
                try self.startEncoding()
            } catch {
                self.portWaiters.forEach { $0(.failure(error)) }
                self.portWaiters = []
            }
        }
    }

    /// MPEG-TS mode: sends to 127.0.0.1:`port` (changes target if already running).
    func startTS(to port: UInt16) {
        queue.async {
            self.tsPort = port
            self.log.log("Test-Encoder: MPEG-TS über UDP an 127.0.0.1:\(port)", "sim")
            do {
                if self.udpOut == nil { self.udpOut = try UDPReceiver(port: 0, queue: self.queue) { _, _ in } }
                try self.startEncoding()
            } catch {
                self.log.log("Test-Encoder: \(error.localizedDescription)", "sim")
            }
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.video = nil
            self.audio = nil
            self.listener?.cancel()
            self.listener = nil
            self.rtspPort = nil
            self.sessions.values.forEach { $0.connection.cancel() }
            self.sessions = [:]
            self.udpOut?.cancel()
            self.udpOut = nil
            self.tsPort = nil
        }
    }

    // MARK: Encoding

    private func startEncoding() throws {
        guard timer == nil else { return }
        guard let v = H264TestEncoder(width: Self.width, height: Self.height, fps: Self.fps, bitrate: 4_000_000, onFrame: { [weak self] f in
            self?.queue.async { self?.send(f) }
        }) else { throw StreamError.unsupported("H.264-Encoder konnte nicht erstellt werden") }
        video = v
        audio = AACTestEncoder(sampleRate: Double(Self.sampleRate), channels: 2)
        if audio == nil { log.log("Test-Encoder: AAC-Encoder nicht verfügbar – nur Bild", "sim") }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(Self.fps), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func whenFirstFrame(_ f: @escaping () -> Void) {
        if hasFirstFrame { f() } else { firstFrameWaiters.append(f) }
    }

    private func tick() {
        guard let video else { return }
        if let pb = Self.pattern(frame: frameIndex) {
            video.encode(pb, pts: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(Self.fps)))
        }
        frameIndex += 1
        // Sound keeps pace with the pictures.
        let videoTime = Double(frameIndex) / Double(Self.fps)
        while let audio, Double(audioSamples) / Double(Self.sampleRate) < videoTime {
            let base = audioSamples
            let packets = audio.encode { _, i in Self.tone(base + i) }
            audioSamples += Int(audio.frameCount)
            for p in packets {
                send(aac: p, index: audioPackets, config: audio.config)
                audioPackets += 1
            }
        }
    }

    /// 1 kHz beep for 0.2 s at the start of every second, −12 dBFS.
    private static func tone(_ sample: Int) -> Float {
        guard sample % sampleRate < sampleRate / 5 else { return 0 }
        return 0.25 * Float(sin(2 * Double.pi * 1000 * Double(sample) / Double(sampleRate)))
    }

    private func send(_ f: H264TestEncoder.Frame) {
        if !hasFirstFrame {
            hasFirstFrame = true
            firstFrameWaiters.forEach { $0() }
            firstFrameWaiters = []
        }
        let seconds = f.pts.seconds
        if let tsPort {
            sendTS(muxer.video(f.nals, pts: seconds + 1, keyframe: f.isKeyframe), port: tsPort)
        }
        let ts = UInt32(truncatingIfNeeded: Int64((seconds * 90_000).rounded()))
        let packets = Self.packetizeH264(f.nals)
        for (i, payload) in packets.enumerated() {
            sendRTP(track: 0, payloadType: 96, marker: i == packets.count - 1, timestamp: ts, payload: payload)
        }
    }

    private func send(aac: Data, index: Int, config: AACConfig) {
        let seconds = Double(index * 1024) / config.sampleRate
        if let tsPort {
            sendTS(muxer.audio(aac, config: config, pts: seconds + 1), port: tsPort)
        }
        // RFC 3640 AAC-hbr: 16 bit AU-headers-length, one AU header (13 bit size, 3 bit index).
        var payload = Data([0x00, 0x10, UInt8((aac.count >> 5) & 0xff), UInt8((aac.count & 0x1f) << 3)])
        payload.append(aac)
        sendRTP(track: 1, payloadType: 97, marker: true, timestamp: UInt32(truncatingIfNeeded: index * 1024), payload: payload)
    }

    /// Single NAL units, or FU-A fragments for the big ones (RFC 6184).
    static func packetizeH264(_ nals: [Data], mtu: Int = 1400) -> [Data] {
        var out: [Data] = []
        for nal in nals {
            let b = [UInt8](nal)
            guard !b.isEmpty else { continue }
            if b.count <= mtu { out.append(Data(b)); continue }
            var offset = 1
            while offset < b.count {
                let n = min(mtu - 2, b.count - offset)
                let start = offset == 1, end = offset + n == b.count
                var p = Data([(b[0] & 0xe0) | 28, (start ? 0x80 : 0) | (end ? 0x40 : 0) | (b[0] & 0x1f)])
                p.append(contentsOf: b[offset..<(offset + n)])
                out.append(p)
                offset += n
            }
        }
        return out
    }

    private func sendRTP(track: Int, payloadType: Int, marker: Bool, timestamp: UInt32, payload: Data) {
        for s in sessions.values where s.playing {
            guard s.channel[track] != nil || s.udpPort[track] != nil else { continue }
            let seq = s.sequence[track, default: 0]
            s.sequence[track] = seq &+ 1
            let packet = RTPPacket.make(payloadType: payloadType, marker: marker, sequence: seq, timestamp: timestamp,
                                        ssrc: track == 0 ? Self.videoSSRC : Self.audioSSRC, payload: payload)
            if let channel = s.channel[track] {
                var frame = Data([0x24, channel, UInt8(packet.count >> 8), UInt8(packet.count & 0xff)])
                frame.append(packet)
                s.connection.send(content: frame, completion: .idempotent)
            } else if let port = s.udpPort[track] {
                udpOut?.send(packet, to: "127.0.0.1", port: port)
            }
        }
    }

    /// 7 TS packets per datagram (1316 bytes), like encoders do.
    private func sendTS(_ packets: [Data], port: UInt16) {
        tsPending += packets
        while tsPending.count >= 7 {
            udpOut?.send(tsPending.prefix(7).reduce(Data(), +), to: "127.0.0.1", port: port)
            tsPending.removeFirst(7)
        }
    }

    // MARK: RTSP server

    private func accept(_ c: NWConnection) {
        let s = Session(c)
        let id = ObjectIdentifier(s)
        sessions[id] = s
        log.log("Test-Encoder: Client verbunden (\(c.endpoint))", "sim")
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.sessions[id] = nil
            default: break
            }
        }
        c.start(queue: queue)
        receive(s, id: id)
    }

    private func receive(_ s: Session, id: ObjectIdentifier) {
        s.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                s.parser.append(data)
                while let item = s.parser.next() {
                    if case .request(let method, let uri, let headers, _) = item { self.handle(s, method: method, uri: uri, headers: headers) }
                }
            }
            if complete || error != nil {
                s.connection.cancel()
                self.sessions[id] = nil
                return
            }
            self.receive(s, id: id)
        }
    }

    private func handle(_ s: Session, method: String, uri: String, headers: [String: String]) {
        var status = "200 OK"
        var reply: [(String, String)] = []
        var body = ""
        var close = false
        switch method {
        case "OPTIONS", "GET_PARAMETER", "SET_PARAMETER":
            reply.append(("Public", "OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"))
        case "DESCRIBE":
            guard uri.hasSuffix("/stream1") || uri.hasSuffix("/stream1/") else { status = "404 Not Found"; break }
            body = sdp()
            reply += [("Content-Type", "application/sdp"), ("Content-Base", "rtsp://127.0.0.1:\(rtspPort ?? 0)/stream1/")]
        case "SETUP":
            let track = uri.hasSuffix("trackID=1") ? 1 : 0
            let transport = headers["transport"] ?? ""
            if let r = transport.range(of: "interleaved=") {
                let first = UInt8(transport[r.upperBound...].prefix { $0.isNumber }) ?? UInt8(track * 2)
                s.channel[track] = first
                reply.append(("Transport", "RTP/AVP/TCP;unicast;interleaved=\(first)-\(first + 1)"))
            } else if let r = transport.range(of: "client_port=") {
                let port = UInt16(transport[r.upperBound...].prefix { $0.isNumber }) ?? 0
                s.udpPort[track] = port
                let server = udpOut?.port ?? 0
                reply.append(("Transport", "RTP/AVP;unicast;client_port=\(port)-\(port + 1);server_port=\(server)-\(server + 1)"))
            } else {
                status = "461 Unsupported Transport"
            }
            reply.append(("Session", "\(Self.sessionID);timeout=60"))
        case "PLAY":
            s.playing = true
            reply += [("Session", Self.sessionID), ("Range", "npt=0.000-")]
            log.log("Test-Encoder: PLAY (\(s.channel.isEmpty ? "UDP" : "TCP interleaved"))", "sim")
        case "TEARDOWN":
            s.playing = false
            close = true
        default:
            status = "405 Method Not Allowed"
        }
        var lines = ["RTSP/1.0 \(status)", "CSeq: \(headers["cseq"] ?? "0")", "Server: Kuhtake-Testencoder"]
        lines += reply.map { "\($0.0): \($0.1)" }
        if !body.isEmpty { lines.append("Content-Length: \(body.utf8.count)") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        s.connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in if close { s.connection.cancel() } })
    }

    private func sdp() -> String {
        var lines = ["v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=Kuhtake Test-Encoder", "c=IN IP4 127.0.0.1", "t=0 0", "a=control:*",
                     "m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000"]
        var fmtp = "a=fmtp:96 packetization-mode=1"
        if let sps = video?.sps, let pps = video?.pps {
            fmtp += ";sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())"
        }
        lines += [fmtp, "a=control:trackID=0"]
        if let audio {
            let config = audio.config.asc.map { String(format: "%02x", $0) }.joined()
            lines += ["m=audio 0 RTP/AVP 97", "a=rtpmap:97 MPEG4-GENERIC/\(Int(audio.config.sampleRate))/\(audio.config.channels)",
                      "a=fmtp:97 streamtype=5;profile-level-id=15;mode=AAC-hbr;config=\(config);sizelength=13;indexlength=3;indexdeltalength=3",
                      "a=control:trackID=1"]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Test pattern

    private static let barColors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0), (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75),
    ]

    /// Colour bars, a moving box and the running timecode.
    static func pattern(frame: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let barWidth = w / CGFloat(barColors.count)
        for (i, c) in barColors.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: h * 0.35, width: barWidth + 1, height: h * 0.65))
        }
        // Moving box: one pass across the picture every 4 seconds.
        let travel = Double(frame % (fps * 4)) / Double(fps * 4)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(travel) * (w - 80), y: h * 0.35 - 100, width: 80, height: 80))
        // Timecode HH:MM:SS:FF.
        let f = frame % fps, s = frame / fps
        let tc = String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 64, nil)
        let text = NSAttributedString(string: "KUHTAKE TEST  " + tc, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = CGPoint(x: 40, y: 40)
        CTLineDraw(line, ctx)
        return pb
    }
}

// MARK: - Command line self test

/// `Kuhtake --stream-selftest [address] [seconds] [--record file.mov]`: receives a stream without the UI and prints the
/// protocol log and statistics; with `--record` it also goes through the recorder like a take in the app.
/// `--take <project folder>` records like the app does (temp file in `TempRecordings.folder`, then copied into the
/// folder and checked). Without an address the built-in test encoder is used. Exit code 0 when everything worked.
enum StreamSelfTest {
    private final class CountingSink: CaptureSink {
        let lock = NSLock()
        var videoFrames = 0
        var audioBuffers = 0
        var recorder: Recorder?
        func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
            lock.withLock { videoFrames += 1 }
            recorder?.appendVideo(pixelBuffer, pts: pts)
        }
        func appendAudio(_ sampleBuffer: CMSampleBuffer) {
            lock.withLock { audioBuffers += 1 }
            recorder?.appendAudio(sampleBuffer)
        }
    }

    static func run(arguments: [String]) -> Never {
        StreamLog.shared.echo = true
        var args = arguments
        var recordURL: URL?
        if let i = args.firstIndex(of: "--record"), i + 1 < args.count {
            recordURL = URL(fileURLWithPath: args[i + 1])
            args.removeSubrange(i...(i + 1))
        }
        var takeFolder: URL?
        if let i = args.firstIndex(of: "--take"), i + 1 < args.count {
            takeFolder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            args.removeSubrange(i...(i + 1))
            TempRecordings.removeHandled()
            recordURL = try? TempRecordings.newFile()
            print("=== Temporäre Aufnahme: \(recordURL?.path ?? "?")")
        }
        let address = args.first ?? StreamAddress.Mode.rtsp.address
        let seconds = args.count > 1 ? Double(args[1]) ?? 8 : 8
        let hub = FrameHub()
        let sink = CountingSink()
        if let recordURL {
            if takeFolder == nil { try? FileManager.default.removeItem(at: recordURL) }
            sink.recorder = Recorder(url: recordURL, config: .init(container: .mov, codec: .h264, resolution: .native, frameRate: .fps25,
                                                                   bitrateMbps: 10, audio: true, timecode: nil))
        }
        hub.sink = sink
        let engine = TeradekStreamEngine(hub: hub)
        engine.onStateChange = { print("=== Zustand: \($0)") }
        engine.start(address: address)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print("=== Statistik")
        engine.diagnostics.forEach { print("    " + $0) }
        let (video, audio) = sink.lock.withLock { (sink.videoFrames, sink.audioBuffers) }
        print("=== Ergebnis: \(video) Bilder, \(audio) Tonpuffer in \(Int(seconds)) s")
        engine.stop()
        var recorded = true
        if let recorder = sink.recorder {
            var result: Swift.Result<Recorder.Result, Error>?
            recorder.finish { result = $0 }
            let deadline = Date().addingTimeInterval(10)
            while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            switch result {
            case .success(let r):
                let asset = AVURLAsset(url: r.url, options: [AVURLAssetOverrideMIMETypeKey: r.fileExtension == "mp4" ? "video/mp4" : "video/quicktime"])
                let tracks = asset.tracks.map { t in
                    "\(t.mediaType.rawValue) \(t.mediaType == .video ? "\(Int(t.naturalSize.width))×\(Int(t.naturalSize.height)) \(String(format: "%.2f", t.nominalFrameRate)) fps" : "")"
                }
                print("=== Aufnahme: \(r.url.path) · \(String(format: "%.2f", r.duration)) s · Spuren: \(tracks.joined(separator: ", "))")
                recorded = asset.tracks.contains { $0.mediaType == .video }
                if let takeFolder {
                    do {
                        let target = try ClipNaming.store(tempFile: r.url, as: ClipName(scene: "1", shot: 1, take: 1),
                                                          fileExtension: r.fileExtension, into: takeFolder)
                        TempRecordings.markStored(r.url, as: target)
                        print("=== Gespeichert und geprüft: \(target.path)")
                    } catch {
                        print("=== Speichern fehlgeschlagen: \(error.localizedDescription)")
                        recorded = false
                    }
                }
            case .failure(let e):
                print("=== Aufnahme fehlgeschlagen: \(e.localizedDescription)")
                recorded = false
            case nil:
                print("=== Aufnahme: keine Rückmeldung vom Recorder")
                recorded = false
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        exit(video > 0 && recorded ? 0 : 1)
    }
}
