import CoreVideo
import Foundation

/// Watches a region of the captured frame and reports when it deviates from the stored
/// "idle" baseline (e.g. a camera's REC tally lighting up) and when it returns to it.
final class MotionDetector: ObservableObject {
    static let grid = 24

    @Published private(set) var score: Double = 0
    @Published private(set) var isActive = false

    /// Called on the main queue: true = change detected (start), false = back to idle (stop).
    var onTrigger: ((Bool) -> Void)?
    var pixelBufferProvider: (() -> CVPixelBuffer?)?

    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "kuhtake.detector", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pendingSince: Date?
    private var stableState = false
    private var baselineRequested = false

    // Snapshot of settings, refreshed on the main queue.
    private struct Params {
        var region: CGRect, shape: RegionShape, sensitivity: Double
        var startDelay: Double, stopDelay: Double, baseline: [Float]?
    }
    private var params: Params

    init() {
        params = Params(region: .zero, shape: .rectangle, sensitivity: 0.5, startDelay: 0, stopDelay: 0, baseline: nil)
        refreshParams()
    }

    /// Thresholds derived from the sensitivity slider.
    static func thresholds(sensitivity s: Double) -> (colorTolerance: Float, changedFraction: Double) {
        (Float(0.30 - 0.22 * s), 0.50 - 0.47 * s)
    }

    var currentThreshold: Double { Self.thresholds(sensitivity: settings.sensitivity).changedFraction }

    func refreshParams() {
        let p = Params(region: settings.region, shape: settings.regionShape, sensitivity: settings.sensitivity,
                       startDelay: settings.startDelay, stopDelay: settings.stopDelay, baseline: settings.baseline)
        queue.async { self.params = p }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Stores the current look of the region as the "not recording" state.
    func captureBaseline() {
        queue.async {
            self.baselineRequested = true
        }
    }

    private func tick() {
        guard let pb = pixelBufferProvider?() else { return }
        let p = params
        guard let signature = Self.signature(of: pb, region: p.region, shape: p.shape) else { return }

        if baselineRequested || p.baseline?.count != signature.count {
            baselineRequested = false
            params.baseline = signature
            stableState = false
            pendingSince = nil
            DispatchQueue.main.async {
                self.settings.baseline = signature
                self.score = 0
                self.isActive = false
            }
            return
        }
        guard let baseline = p.baseline else { return }

        let (tolerance, fraction) = Self.thresholds(sensitivity: p.sensitivity)
        var valid = 0, changed = 0
        var i = 0
        while i < signature.count {
            if signature[i] >= 0 {
                valid += 1
                let d = max(abs(signature[i] - baseline[i]), abs(signature[i + 1] - baseline[i + 1]), abs(signature[i + 2] - baseline[i + 2]))
                if d > tolerance { changed += 1 }
            }
            i += 3
        }
        let score = valid > 0 ? Double(changed) / Double(valid) : 0
        let active = score >= fraction

        var fire: Bool?
        if active != stableState {
            let now = Date()
            if pendingSince == nil { pendingSince = now }
            let delay = active ? p.startDelay : p.stopDelay
            if now.timeIntervalSince(pendingSince!) >= delay {
                stableState = active
                pendingSince = nil
                fire = active
            }
        } else {
            pendingSince = nil
        }

        let state = stableState
        DispatchQueue.main.async {
            self.score = score
            self.isActive = state
            if let fire { self.onTrigger?(fire) }
        }
    }

    /// Average color per grid cell (RGB triplets 0…1). Cells outside an ellipse are marked with -1.
    static func signature(of pb: CVPixelBuffer, region: CGRect, shape: RegionShape) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let r = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }

        let n = grid
        var out = [Float](repeating: -1, count: n * n * 3)
        let rx = r.minX * CGFloat(width), ry = r.minY * CGFloat(height)
        let rw = r.width * CGFloat(width), rh = r.height * CGFloat(height)

        for gy in 0..<n {
            for gx in 0..<n {
                let cx = (CGFloat(gx) + 0.5) / CGFloat(n), cy = (CGFloat(gy) + 0.5) / CGFloat(n)
                if shape == .ellipse {
                    let dx = cx - 0.5, dy = cy - 0.5
                    if dx * dx + dy * dy > 0.25 { continue }
                }
                var sr = 0, sg = 0, sb = 0, count = 0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let fx = (CGFloat(gx) + (CGFloat(sx) + 0.5) / 3) / CGFloat(n)
                        let fy = (CGFloat(gy) + (CGFloat(sy) + 0.5) / 3) / CGFloat(n)
                        let px = min(width - 1, max(0, Int(rx + fx * rw)))
                        let py = min(height - 1, max(0, Int(ry + fy * rh)))
                        let p = base + py * bpr + px * 4
                        sb += Int(p[0]); sg += Int(p[1]); sr += Int(p[2])
                        count += 1
                    }
                }
                let o = (gy * n + gx) * 3
                let div = Float(count) * 255
                out[o] = Float(sr) / div
                out[o + 1] = Float(sg) / div
                out[o + 2] = Float(sb) / div
            }
        }
        return out
    }
}
