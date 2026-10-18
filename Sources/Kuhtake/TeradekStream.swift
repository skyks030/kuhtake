import AVFoundation
import CoreMedia
import Foundation
import Network

/// The network stream of a Teradek encoder (Cube, Bond, Prism … – or anything else that sends RTSP, MPEG-TS or HLS)
/// as an input: received, depacketized and decoded natively, delivered to the frame hub like the other inputs.
/// A lost or refused connection is retried by itself every few seconds.
///
/// Everything below `start`/`stop` runs on the engine's own queue; state and diagnostics are published to the main queue.
final class TeradekStreamEngine: StreamMediaOutput {
    enum State: Equatable {
        case idle
        case connecting(String)
        /// Pictures are coming.
        case running
        /// Connected / listening, but no picture (yet).
        case waiting(String)
        /// Lost or refused; `retrying`: a new attempt follows by itself.
        case failed(String, retrying: Bool)
    }

    private let hub: FrameHub
    private let queue = DispatchQueue(label: "kuhtake.stream", qos: .userInteractive)
    private let log = StreamLog.shared

    // MARK: Main queue

    /// Main queue.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle
    /// What was passed to `start` (nil = stopped).
    private(set) var addressText: String?
    /// Codec, resolution and transport once the decoder runs, e.g. "H.264 1920×1080 · RTSP/TCP".
    private(set) var signalFormat: String?
    /// Detailed statistics for the settings window and the diagnosis report (once a second).
    private(set) var diagnostics: [String] = []
    private(set) var reconnects = 0
    /// Increased on every start/stop: results of an earlier run are dropped.
    private var token = 0

    // MARK: Engine queue

    private var address: StreamAddress?
    private var runToken = 0
    /// Increased on every connection attempt.
    private var generation = 0
    private var rtsp: RTSPClient?
    private var udp: UDPReceiver?
    private var tcp: NWConnection?
    private var hls: HLSReceiver?
    private var demuxer: TSDemuxer?
    private var simulator: TeradekSimulator?
    private var decoder: VideoStreamDecoder?
    private var audioDecoder: AACDecoder?
    private var videoClock = StreamClock()
    private var audioClock = StreamClock()
    /// Automatic mode: RTSP addresses still to try, and the one that worked last.
    private var probe: [URL] = []
    private var foundURL: URL?
    private var transport = ""
    private var attemptStartedAt = 0.0
    private var lastDataAt = 0.0
    private var lastPictureCount = 0
    private var lastPictureAt = 0.0
    private var pictureFlowing = false
    private var retry: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    /// Pictures still inside the decoder after a stop or reconnect must not reach the hub.
    private let liveLock = NSLock()
    private var liveGeneration = -1

    init(hub: FrameHub) {
        self.hub = hub
    }

    // MARK: Start / stop (main queue)

    func start(address raw: String) {
        // Already on it – unless it gave up for good (then selecting it again is a new try).
        if addressText == raw, state != .idle, !state.isFinalFailure { return }
        stop()
        addressText = raw
        reconnects = 0
        token += 1
        let t = token
        guard let address = StreamAddress.parse(raw) else {
            setState(.failed("„\(raw)“ ist keine gültige Stream-Adresse", retrying: false))
            return
        }
        setState(.connecting("Verbinde mit \(address.displayName) …"))
        queue.async {
            self.runToken = t
            self.address = address
            self.foundURL = nil
            self.log.log("Start: \(address.displayName)", "engine")
            self.startWatchdog()
            self.connect()
        }
    }

    func stop() {
        guard addressText != nil else { return }
        addressText = nil
        signalFormat = nil
        diagnostics = []
        token += 1
        queue.async {
            if self.address != nil { self.log.log("Stopp", "engine") }
            self.address = nil
            self.watchdog?.cancel()
            self.watchdog = nil
            self.teardown(keepSimulator: false)
        }
        hub.reset()
        setState(.idle)
    }

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }

    /// From the engine queue.
    private func post(_ s: State) {
        let t = runToken
        DispatchQueue.main.async {
            guard t == self.token else { return }
            self.setState(s)
        }
    }

    // MARK: Connecting (engine queue)

    private func connect() {
        guard let address else { return }
        teardown(keepSimulator: true)
        generation += 1
        let gen = generation
        liveLock.withLock { liveGeneration = gen }
        let clock = StreamClock()
        videoClock = clock
        audioClock = StreamClock()
        decoder = VideoStreamDecoder(clock: clock) { [weak self, hub] pb, pts in
            guard let self, self.liveLock.withLock({ self.liveGeneration == gen }) else { return }
            hub.pushVideo(pb, pts: pts)
        }
        attemptStartedAt = StreamClock.hostNow
        lastDataAt = 0
        lastPictureCount = 0
        lastPictureAt = 0
        pictureFlowing = false

        switch address {
        case .rtsp(let url, let preferUDP):
            startRTSP(url, udp: preferUDP, probing: false)
        case .auto(let host):
            let all = Self.probeURLs(host: host)
            probe = foundURL.map { found in [found] + all.filter { $0 != found } } ?? all
            probeNext(host: host)
        case .tsUDP(let port, let group):
            startTSUDP(port: port, group: group)
        case .tsTCP(let host, let port):
            startTSTCP(host: host, port: port)
        case .hls(let url):
            startHLS(url)
        case .srt:
            fail("SRT wird (noch) nicht unterstützt – am Encoder RTSP oder MPEG-TS einstellen", retry: false)
        case .simulator(let mode):
            startSimulator(mode)
        }
    }

    /// Stops all receivers of the current attempt.
    private func teardown(keepSimulator: Bool) {
        retry?.cancel()
        retry = nil
        liveLock.withLock { liveGeneration = -1 }
        if let rtsp {
            rtsp.onFailure = nil
            rtsp.onPlaying = nil
            rtsp.stop()
        }
        rtsp = nil
        udp?.cancel()
        udp = nil
        tcp?.cancel()
        tcp = nil
        hls?.stop()
        hls = nil
        demuxer = nil
        decoder?.reset()
        decoder = nil
        audioDecoder = nil
        if !keepSimulator {
            simulator?.stop()
            simulator = nil
        }
    }

    private func fail(_ reason: String, retry shouldRetry: Bool = true) {
        generation += 1   // later callbacks of the failed attempt are dropped
        teardown(keepSimulator: true)
        log.log("Fehler: \(reason)\(shouldRetry ? " – neuer Versuch in 3 s" : "")", "engine")
        post(.failed(reason, retrying: shouldRetry))
        guard shouldRetry else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.address != nil else { return }
            let t = self.runToken
            DispatchQueue.main.async { if t == self.token { self.reconnects += 1 } }
            self.connect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func noteData() {
        lastDataAt = StreamClock.hostNow
    }

    // MARK: RTSP

    private func startRTSP(_ url: URL, udp: Bool, probing: Bool) {
        let gen = generation
        let client = RTSPClient(url: url, useUDP: udp, queue: queue, output: self)
        var played = false
        client.onPlaying = { [weak self] in
            guard let self, gen == self.generation else { return }
            played = true
            if probing {
                if self.foundURL != url { self.log.log("Stream gefunden: \(url.redactingPassword)", "engine") }
                self.foundURL = url
            }
            self.post(.connecting("Stream läuft – warte auf das erste Bild …"))
        }
        client.onFailure = { [weak self, unowned client] reason in
            guard let self, gen == self.generation else { return }
            if probing, !played {
                self.probeFailed(client, reason: reason)
            } else {
                self.fail(reason)
            }
        }
        rtsp = client
        transport = udp ? "RTSP/UDP" : "RTSP/TCP"
        client.start()
    }

    /// Where Teradek encoders (and most others) offer their RTSP stream.
    static func probeURLs(host: String) -> [URL] {
        let paths = ["/stream1", "/stream", "/live", "/", "/h264", "/stream2"]
        return [554, 8554].flatMap { port in paths.compactMap { URL(string: "rtsp://\(host):\(port)\($0)") } }
    }

    private func probeNext(host: String) {
        guard !probe.isEmpty else {
            fail("Am Encoder \(StreamAddress.auto(host: host).shortName) wurde kein RTSP-Stream gefunden (Ports 554 und 8554). "
                 + "Am Encoder RTSP aktivieren oder die Stream-Adresse direkt eingeben (rtsp://…, udp://@:Port).")
            return
        }
        let url = probe.removeFirst()
        post(.connecting("Suche Stream: \(url.redactingPassword) …"))
        startRTSP(url, udp: false, probing: true)
    }

    private func probeFailed(_ client: RTSPClient, reason: String) {
        rtsp = nil
        // Credentials are needed (or wrong): guessing further paths won't help.
        if client.lastStatus == 401 || reason.contains("(401)") {
            fail(reason)
            return
        }
        // Nothing listens on that port: skip its other paths.
        if !client.connected { probe.removeAll { $0.port == client.url.port } }
        guard case .auto(let host) = address else { return }
        probeNext(host: host)
    }

    // MARK: MPEG-TS

    private func startTSUDP(port: UInt16, group: String?) {
        let gen = generation
        let demux = TSDemuxer(output: self)
        demuxer = demux
        audioClock = videoClock   // video and audio share the PES clock
        transport = "MPEG-TS/UDP"
        do {
            udp = try UDPReceiver(port: port, group: group, queue: queue) { [weak self] data, sender in
                guard let self, gen == self.generation else { return }
                if self.lastDataAt == 0 { self.log.log("Erste UDP-Daten von \(sender), \(data.count) Bytes", "ts") }
                self.noteData()
                demux.feed(data, datagram: true)
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        let actual = udp?.port ?? port
        log.log("Warte auf MPEG-TS an UDP-Port \(actual)\(group.map { " (Multicast \($0))" } ?? "")", "ts")
        post(.waiting("Warte auf MPEG-TS an UDP-Port \(actual) …"))
    }

    private func startTSTCP(host: String, port: UInt16) {
        let gen = generation
        let demux = TSDemuxer(output: self)
        demuxer = demux
        audioClock = videoClock
        transport = "MPEG-TS/TCP"
        guard let p = NWEndpoint.Port(rawValue: port) else { fail("Ungültiger Port \(port)", retry: false); return }
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 5
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        tcp = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                self.log.log("TCP verbunden mit \(host):\(port)", "ts")
                self.post(.connecting("Verbunden – warte auf das erste Bild …"))
                self.receiveTS(c, demux: demux, generation: gen)
            case .waiting(let e), .failed(let e):
                self.fail("Verbindung zu \(host):\(port) fehlgeschlagen: \(e.localizedDescription)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func receiveTS(_ c: NWConnection, demux: TSDemuxer, generation gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, gen == self.generation else { return }
            if let data, !data.isEmpty {
                self.noteData()
                demux.feed(data)
            }
            if let error { self.fail("Empfang: \(error.localizedDescription)"); return }
            if complete { self.fail("Der Encoder hat die Verbindung geschlossen"); return }
            self.receiveTS(c, demux: demux, generation: gen)
        }
    }

    // MARK: HLS

    private func startHLS(_ url: URL) {
        let gen = generation
        transport = "HLS"
        decoder = nil   // AVPlayer decodes itself
        log.log("HLS: \(url.redactingPassword) (Bild über AVPlayer, ohne Ton)", "hls")
        hls = HLSReceiver(url: url, queue: queue, onPicture: { [weak self, hub] pb, pts in
            guard let self, gen == self.generation else { return }
            self.noteData()
            hub.pushVideo(pb, pts: pts)
        }, onFailure: { [weak self] reason in
            guard let self, gen == self.generation else { return }
            self.fail(reason)
        })
    }

    // MARK: Simulator

    private func startSimulator(_ mode: StreamAddress.Mode) {
        let gen = generation
        let sim = simulator ?? TeradekSimulator()
        simulator = sim
        switch mode {
        case .ts:
            startTSUDP(port: 0, group: nil)
            guard let port = udp?.port else { return }
            sim.startTS(to: port)
        case .rtsp, .rtspUDP:
            post(.connecting("Test-Encoder startet …"))
            sim.startRTSP { [weak self] result in
                self?.queue.async {
                    guard let self, gen == self.generation else { return }
                    switch result {
                    case .success(let port):
                        self.startRTSP(URL(string: "rtsp://127.0.0.1:\(port)/stream1")!, udp: mode == .rtspUDP, probing: false)
                    case .failure(let error):
                        self.fail("Test-Encoder: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: Watchdog & statistics

    private func startWatchdog() {
        watchdog?.cancel()
        let w = DispatchSource.makeTimerSource(queue: queue)
        w.schedule(deadline: .now() + 0.5, repeating: 0.5)
        w.setEventHandler { [weak self] in self?.check() }
        w.resume()
        watchdog = w
    }

    private func check() {
        guard address != nil else { return }
        let now = StreamClock.hostNow
        let pictures = (decoder?.decodedFrames ?? 0) + (hls?.frames ?? 0)
        if pictures > lastPictureCount {
            lastPictureAt = now
            if !pictureFlowing {
                pictureFlowing = true
                log.log("Bild läuft: \(decoder?.summary ?? "HLS")", "engine")
                post(.running)
            }
        }
        lastPictureCount = pictures
        let attemptActive = decoder != nil || hls != nil
        if attemptActive, retry == nil {
            let sincePicture = now - (lastPictureAt > 0 ? lastPictureAt : attemptStartedAt)
            if pictureFlowing, sincePicture > 2 {
                pictureFlowing = false
                post(.waiting("Seit \(Int(sincePicture)) s kein Bild"))
            }
            if !pictureFlowing, sincePicture > 4 {
                checkStalled(now: now)
            }
        }
        publishStatistics()
    }

    /// No picture for a while: say why, and reconnect where waiting won't help.
    private func checkStalled(now: Double) {
        let dataAge = lastDataAt > 0 ? now - lastDataAt : now - attemptStartedAt
        switch address {
        case .tsUDP(let port, _):
            if dataAge > 3 {
                post(.waiting("Keine Daten an UDP-Port \(port) – am Encoder MPEG-TS/UDP an die IP dieses Macs, Port \(port) senden"))
                return
            }
        case .simulator(.ts):
            if dataAge > 3 { post(.waiting("Keine Daten vom Test-Encoder")); return }
        case .tsTCP, .hls:
            if dataAge > 6 { fail("Seit \(Int(dataAge)) Sekunden keine Daten"); return }
        default:
            break   // RTSP has its own data watchdog
        }
        guard lastDataAt > 0, let decoder else { return }
        var why = "Daten kommen an, aber kein Bild"
        if let demuxer, demuxer.stats.packets > 0, !demuxer.stats.streams.isEmpty,
           !demuxer.stats.streams.values.contains(where: { $0 == 0x1b || $0 == 0x24 }) {
            why += " – kein H.264-/HEVC-Video im Transportstrom"
        } else if decoder.droppedWaitingForParameters > 0, decoder.decodedFrames == 0 {
            why += " – warte auf Parameter-Sets (Keyframe)"
        } else if decoder.decodeErrors > 0 {
            why += " – \(decoder.decodeErrors) Dekodierfehler"
        }
        post(.waiting(why))
    }

    private func publishStatistics() {
        guard let address else { return }
        var lines = ["Adresse: \(address.displayName)"]
        var t = transport
        if case .auto = address, let foundURL { t += " · \(foundURL.redactingPassword)" }
        lines.append("Transport: \(t)")
        var format: String?
        if let decoder {
            lines.append("Video: \(decoder.summary) · \(decoder.decodedFrames) Bilder · \(decoder.keyframes) Keyframes · \(decoder.decodeErrors) Fehler")
            if decoder.dimensions != nil { format = "\(decoder.summary) · \(transport)" }
        }
        if let hls {
            lines.append("Video: HLS \(hls.size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?") · \(hls.frames) Bilder · ohne Ton")
            if let s = hls.size { format = "HLS \(Int(s.width))×\(Int(s.height))" }
        }
        if let rtsp {
            let s = rtsp.stats
            lines.append("RTP: \(s.rtpPackets) Pakete · \(String(format: "%.1f", Double(s.rtpBytes) / 1_000_000)) MB · \(s.lostPackets) verloren")
        }
        if let demuxer {
            let s = demuxer.stats
            lines.append("TS: \(s.packets) Pakete · \(s.syncLosses) Sync-Verluste · \(s.continuityErrors) CC-Fehler\(s.rtpWrapped ? " · in RTP" : "")")
        }
        if let audioDecoder {
            lines.append("Ton: \(audioDecoder.config.summary) · \(audioDecoder.decodedFrames) Frames · \(audioDecoder.errors) Fehler")
        } else if hls == nil {
            lines.append("Ton: keiner")
        }
        let t2 = runToken
        DispatchQueue.main.async {
            guard t2 == self.token else { return }
            if self.diagnostics != lines { self.diagnostics = lines }
            if self.signalFormat != format { self.signalFormat = format }
        }
    }

    /// Protocol log plus current statistics, for "copy diagnosis".
    var diagnosisReport: String {
        var parts = ["Kuhtake \(RTSPClient.version) – Teradek-Netzwerkstream", "Zustand: \(state)"]
        parts += diagnostics
        parts.append("")
        parts.append(StreamLog.shared.text)
        return parts.joined(separator: "\n")
    }

    // MARK: StreamMediaOutput (engine queue)

    func parameterSets(_ nals: [Data], codec: StreamVideoCodec) {
        decoder?.setParameterSets(nals, codec: codec)
    }

    func video(_ nals: [Data], codec: StreamVideoCodec, time: Double) {
        noteData()
        decoder?.decode(nals, codec: codec, time: time)
    }

    func audioConfig(_ config: AACConfig) {
        guard audioDecoder?.config != config else { return }
        audioDecoder = AACDecoder(config: config)
        log.log(audioDecoder == nil ? "AAC-Decoder für \(config.summary) konnte nicht erstellt werden" : "Ton: \(config.summary)", "decoder")
    }

    func aac(_ frame: Data, time: Double) {
        guard let audioDecoder, let sb = audioDecoder.decode(frame, pts: audioClock.pts(forSource: time)) else { return }
        hub.pushAudio(sb)
    }
}

extension TeradekStreamEngine.State {
    var isFinalFailure: Bool {
        if case .failed(_, retrying: false) = self { return true }
        return false
    }
}

// MARK: - HLS

/// HTTP Live Streaming via AVPlayer: pictures are taken from a video output as they become due (no sound).
private final class HLSReceiver {
    private let player: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ])
    private var timer: DispatchSourceTimer?
    private var status: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private(set) var frames = 0
    private(set) var size: CGSize?

    init(url: URL, queue: DispatchQueue, onPicture: @escaping (CVPixelBuffer, CMTime) -> Void, onFailure: @escaping (String) -> Void) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        status = item.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "Wiedergabe fehlgeschlagen"
            queue.async { onFailure("HLS: \(reason)") }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { n in
            let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            queue.async { onFailure("HLS abgebrochen: \(e?.localizedDescription ?? "unbekannter Fehler")") }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { _ in
            queue.async { onFailure("Der HLS-Stream ist zu Ende") }
        })
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = StreamClock.hostNow
            let itemTime = self.output.itemTime(forHostTime: now)
            guard self.output.hasNewPixelBuffer(forItemTime: itemTime),
                  let pb = self.output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
            self.frames += 1
            self.size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
            onPicture(pb, CMTime(seconds: now, preferredTimescale: 90_000))
        }
        t.resume()
        timer = t
        player.play()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        status?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Display

extension StreamAddress {
    /// For the UI and logs: like `description`, but never with a password.
    var displayName: String {
        if case .auto(let host) = self, let at = host.lastIndex(of: "@") {
            return "Encoder \(host[host.index(after: at)...]) (automatisch)"
        }
        return description
    }

    /// Short name for the source label.
    var shortName: String {
        switch self {
        case .auto(let host): return host.lastIndex(of: "@").map { String(host[host.index(after: $0)...]) } ?? host
        case .rtsp(let url, _), .hls(let url): return url.host ?? url.redactingPassword
        case .tsUDP(let port, let group): return "\(group ?? "UDP"):\(port)"
        case .tsTCP(let host, let port): return "\(host):\(port)"
        case .srt(let url): return url.host ?? url.absoluteString
        case .simulator(let mode): return "Test-Encoder (\(mode.label))"
        }
    }
}
