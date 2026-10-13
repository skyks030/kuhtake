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

    /// Thresholds derived from the sensitivity slider. Exponential, so the sensitive end stays finely adjustable:
    /// s = 0 → 30 % color change on half the region, s = 1 → 2 % color change on under 1 % of the region.
    static func thresholds(sensitivity s: Double) -> (colorTolerance: Float, changedFraction: Double) {
        (Float(0.30 * pow(0.02 / 0.30, s)), 0.50 * pow(0.0075 / 0.50, s))
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
    /// Reads BGRA (screen capture, DeckLink RGB) and 8-bit 4:2:2 YCbCr '2vuy' (DeckLink YUV).
    static func signature(of pb: CVPixelBuffer, region: CGRect, shape: RegionShape) -> [Float]? {
        let format = CVPixelBufferGetPixelFormatType(pb)
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_422YpCbCr8 else { return nil }
        let isYUV = format == kCVPixelFormatType_422YpCbCr8
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
                var sr: Float = 0, sg: Float = 0, sb: Float = 0, count = 0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let fx = (CGFloat(gx) + (CGFloat(sx) + 0.5) / 3) / CGFloat(n)
                        let fy = (CGFloat(gy) + (CGFloat(sy) + 0.5) / 3) / CGFloat(n)
                        let px = min(width - 1, max(0, Int(rx + fx * rw)))
                        let py = min(height - 1, max(0, Int(ry + fy * rh)))
                        if isYUV {
                            // Cb Y0 Cr Y1 per pixel pair, video range, Rec. 709.
                            let pair = base + py * bpr + (px & ~1) * 2
                            let y = (Float(pair[(px & 1) == 0 ? 1 : 3]) - 16) / 219
                            let cb = (Float(pair[0]) - 128) / 224, cr = (Float(pair[2]) - 128) / 224
                            sr += min(max(y + 1.5748 * cr, 0), 1)
                            sg += min(max(y - 0.1873 * cb - 0.4681 * cr, 0), 1)
                            sb += min(max(y + 1.8556 * cb, 0), 1)
                        } else {
                            let p = base + py * bpr + px * 4
                            sb += Float(p[0]) / 255; sg += Float(p[1]) / 255; sr += Float(p[2]) / 255
                        }
                        count += 1
                    }
                }
                let o = (gy * n + gx) * 3
                let div = Float(count)
                out[o] = sr / div
                out[o + 1] = sg / div
                out[o + 2] = sb / div
            }
        }
        return out
    }
}
