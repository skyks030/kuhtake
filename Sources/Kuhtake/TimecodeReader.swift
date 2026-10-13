import CoreImage
import CoreVideo
import Foundation
import Vision

/// Reads the camera's timecode from the picture: an area of the frame (e.g. the TC display an ARRI Alexa
/// burns into its SDI monitoring out) is read by text recognition a few times a second. Between readings the
/// timecode runs on at the frame rate, so the preview and the recorder get a frame-exact value at any moment.
///
/// Misreadings are filtered: a reading is only accepted if it fits the running timecode, or – after a jump
/// (new roll, TC reset) – once a second reading confirms it. Without an accepted reading for a few seconds the
/// timecode counts as lost and is 00:00:00:00.
final class TimecodeReader: ObservableObject {
    /// Main queue: the text last read in the area (also when it was not usable) – for the setup window.
    @Published private(set) var lastText: String?
    /// Main queue: a timecode is currently recognised.
    @Published private(set) var isLocked = false

    var pixelBufferProvider: (() -> CVPixelBuffer?)?

    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "kuhtake.timecode", qos: .userInitiated)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?

    // Shared with the main queue and the recorder.
    private let lock = NSLock()
    private var anchor: (frames: Int, time: TimeInterval, running: Bool)?
    private var lastAccepted: TimeInterval = 0
    private var countQuanta = 25
    /// During a recording a timecode once recognised never drops out: it keeps running from the last good reading.
    private var holdsWhileRecording = false

    // Reading queue only.
    private var candidate: (frames: Int, time: TimeInterval)?
    private var params = Params(enabled: false, region: .zero, quanta: 25)

    private struct Params { var enabled: Bool; var region: CGRect; var quanta: Int }

    static let interval: TimeInterval = 0.2
    /// Without an accepted reading for this long the timecode is lost.
    static let holdTime: TimeInterval = 3

    init() {
        refreshParams()
    }

    /// Timecode base: frames per second as counted in the timecode (23.976 → 24, 29.97 → 30).
    var quanta: Int { max(1, Int(settings.frameRate.nominal.rounded())) }

    func refreshParams() {
        let p = Params(enabled: settings.timecodeEnabled, region: settings.timecodeRegion, quanta: quanta)
        queue.async {
            if p.quanta != self.params.quanta { self.reset() }
            self.params = p
            self.lock.withLock { self.countQuanta = p.quanta }
            if !p.enabled { self.reset() }
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Reading the current value (any thread)

    /// Frames since 00:00:00:00 right now; nil without a recognised timecode.
    func currentFrames(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        lock.withLock {
            guard let a = anchor, holdsWhileRecording || now - lastAccepted <= Self.holdTime else { return nil }
            let elapsed = a.running ? Int(((now - a.time) * Double(countQuanta)).rounded(.down)) : 0
            return (a.frames + max(0, elapsed)) % (24 * 3600 * countQuanta)
        }
    }

    /// Recording started / stopped. While recording, unsteady or missing readings never reset the timecode –
    /// it runs on from the last accepted value (the file itself counts on from its start timecode anyway).
    func setRecording(_ recording: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if recording {
                // Only a timecode that is recognised at the start is held – an old, long-lost one stays 0.
                holdsWhileRecording = anchor != nil && now - lastAccepted <= Self.holdTime
            } else {
                // After the take, the usual hold time starts now instead of at the last reading.
                if holdsWhileRecording, anchor != nil { lastAccepted = now }
                holdsWhileRecording = false
            }
        }
    }

    /// For the file: the recognised timecode, or 0 when none is recognised.
    func startFrames() -> Int { currentFrames() ?? 0 }

    static func format(frames: Int, quanta: Int) -> String {
        let q = max(1, quanta)
        let f = frames % q, s = frames / q
        return String(format: "%02d:%02d:%02d:%02d", (s / 3600) % 24, (s / 60) % 60, s % 60, f)
    }

    // MARK: Reading the picture (reading queue)

    private func reset() {
        lock.withLock { anchor = nil; lastAccepted = 0; holdsWhileRecording = false }
        candidate = nil
        publish(text: nil)
    }

    private func tick() {
        let p = params
        guard p.enabled, let pb = pixelBufferProvider?() else {
            publishLockState()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let texts = recognize(pb, region: p.region)
        let reading = texts.lazy.compactMap { Self.parse($0, quanta: p.quanta) }.first
        if let reading { consider(reading, at: now, quanta: p.quanta) }
        publish(text: texts.first)
    }

    private func recognize(_ pb: CVPixelBuffer, region: CGRect) -> [String] {
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CVPixelBufferGetHeight(pb)
        let H = CGFloat(h)
        let r = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.005, r.height > 0.005 else { return [] }
        // Core Image has its origin bottom-left.
        let crop = CGRect(x: r.minX * w, y: (1 - r.maxY) * H, width: r.width * w, height: r.height * H).integral
        var image = CIImage(cvPixelBuffer: pb).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        // Small digits read far better a bit larger.
        if crop.height < 64 {
            let s = min(4, 64 / max(crop.height, 1))
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cg = ci.createCGImage(image, from: image.extent) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.2
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return []
        }
        let observations = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        var texts: [String] = []
        // Whole line first (the digits sometimes come as several boxes), then every single candidate.
        let line = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        if !line.isEmpty { texts.append(line) }
        for o in observations {
            texts.append(contentsOf: o.topCandidates(3).map(\.string))
        }
        return texts
    }

    private static let tcPattern = try! NSRegularExpression(
        pattern: #"(\d{1,2})\s*[:;.,]\s*(\d{2})\s*[:;.,]\s*(\d{2})\s*[:;.,]\s*(\d{2})"#)
    private static let digitsPattern = try! NSRegularExpression(pattern: #"(?<!\d)(\d{2})(\d{2})(\d{2})(\d{2})(?!\d)"#)

    /// "TC 01:02:03:04", "01:02:03;04", "01.02.03.04" or eight digits → frames since midnight.
    static func parse(_ raw: String, quanta: Int) -> Int? {
        // Typical misreadings of digits.
        let map: [Character: Character] = ["O": "0", "o": "0", "D": "0", "Q": "0", "I": "1", "l": "1", "|": "1", "!": "1",
                                           "Z": "2", "S": "5", "s": "5", "B": "8", "g": "9"]
        let candidates = [raw, String(raw.map { map[$0] ?? $0 })]
        for s in candidates {
            let range = NSRange(s.startIndex..., in: s)
            for pattern in [tcPattern, digitsPattern] {
                guard let m = pattern.firstMatch(in: s, range: range) else { continue }
                let parts = (1...4).compactMap { Range(m.range(at: $0), in: s).flatMap { Int(s[$0]) } }
                guard parts.count == 4 else { continue }
                let (hh, mm, ss, ff) = (parts[0], parts[1], parts[2], parts[3])
                guard hh < 24, mm < 60, ss < 60, ff < quanta else { continue }
                return ((hh * 60 + mm) * 60 + ss) * quanta + ff
            }
        }
        return nil
    }

    private func consider(_ frames: Int, at now: TimeInterval, quanta: Int) {
        let q = Double(quanta)
        let tolerance = 3
        if let predicted = currentFrames(at: now), abs(predicted - frames) <= tolerance {
            accept(frames, at: now, running: lock.withLock { anchor?.running ?? true })
            candidate = nil
            return
        }
        // A jump or the first reading: wait for a second reading that agrees.
        if let c = candidate {
            let elapsed = now - c.time
            let expectedRunning = c.frames + Int((elapsed * q).rounded())
            if abs(frames - expectedRunning) <= tolerance {
                accept(frames, at: now, running: true)
                candidate = nil
                return
            }
            if abs(frames - c.frames) <= 1, elapsed >= Self.interval * 1.5 {
                // Same value again: the timecode stands (e.g. rec run while the camera doesn't record).
                accept(frames, at: now, running: false)
                candidate = nil
                return
            }
        }
        candidate = (frames, now)
    }

    private func accept(_ frames: Int, at now: TimeInterval, running: Bool) {
        lock.withLock {
            // A standing timecode that starts moving again.
            var run = running
            if let a = anchor, !a.running, frames > a.frames { run = true }
            anchor = (frames, now, run)
            lastAccepted = now
        }
    }

    private func publish(text: String?) {
        let locked = currentFrames() != nil
        DispatchQueue.main.async {
            if self.lastText != text { self.lastText = text }
            if self.isLocked != locked { self.isLocked = locked }
        }
    }

    private func publishLockState() {
        let locked = currentFrames() != nil
        DispatchQueue.main.async { if self.isLocked != locked { self.isLocked = locked } }
    }
}
