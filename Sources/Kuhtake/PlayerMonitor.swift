import AVFoundation
import AppKit
import Combine
import SwiftUI

/// One playback monitor of the source browser: an AVPlayer with frame-accurate scrubbing.
@MainActor
final class MonitorPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var take: TakeFile?
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var fps: Double = 25
    @Published private(set) var isPlaying = false
    /// Current playback speed, negative = backwards (0 while paused).
    @Published private(set) var shuttleRate: Float = 0
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    /// Speeds the player can't do itself (some files can't play backwards) are done by stepping through the clip.
    private var emulation: Timer?
    private var emulatedRate: Float = 0
    private var endObserver: NSObjectProtocol?
    // Scrubbing: only one precise seek at a time, always to the newest target.
    private var isSeeking = false
    private var seekTarget: Double?
    private(set) var isScrubbing = false

    init(muted: Bool = false) {
        isMuted = muted
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isSeeking else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async {
                guard let self, self.emulation == nil else { return }
                self.isPlaying = playing
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let rate = p.rate
            DispatchQueue.main.async {
                guard let self, self.emulation == nil else { return }
                self.shuttleRate = rate
            }
        }
    }

    /// J / L steps: 1×, 2×, 4×, 8× in the pressed direction; the other direction starts again at 1×.
    static let shuttleSteps: [Float] = [1, 2, 4, 8]

    static func nextShuttleRate(after current: Float, forward: Bool) -> Float {
        let sign: Float = forward ? 1 : -1
        guard current != 0, (current > 0) == forward else { return sign }
        let next = shuttleSteps.first { $0 > abs(current) + 0.01 } ?? shuttleSteps.last!
        return sign * next
    }

    func setShuttle(rate: Float) {
        guard isLoaded else { return }
        stopEmulation()
        if rate > 0, isAtEnd { seek(to: 0) }
        if rate < 0, time <= 0.5 / fps { seek(to: duration) }
        let item = player.currentItem
        let supported: Bool
        switch rate {
        case 1: supported = true
        case let r where r > 1: supported = item?.canPlayFastForward ?? false
        case -1: supported = item?.canPlayReverse ?? false
        case let r where r < -1: supported = item?.canPlayFastReverse ?? false
        default: supported = false
        }
        if supported {
            player.rate = rate
        } else {
            startEmulation(rate: rate)
        }
    }

    private func startEmulation(rate: Float) {
        player.pause()
        emulatedRate = rate
        isPlaying = true
        shuttleRate = rate
        let tick = 1.0 / 30
        emulation = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = self.time + Double(self.emulatedRate) * tick
                if next <= 0 || next >= self.duration {
                    self.seek(to: min(max(0, next), self.duration))
                    self.stopEmulation()
                } else {
                    self.seek(to: next)
                }
            }
        }
    }

    private func stopEmulation() {
        guard let emulation else { return }
        emulation.invalidate()
        self.emulation = nil
        emulatedRate = 0
        isPlaying = false
        shuttleRate = 0
    }

    var isLoaded: Bool { take != nil }
    var isAtEnd: Bool { duration > 0 && time >= duration - 0.5 / fps }

    func load(_ take: TakeFile) {
        self.take = take
        let asset = AVURLAsset(url: take.url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        time = 0
        duration = 0
        Task {
            let d = (try? await asset.load(.duration))?.seconds ?? 0
            let rate = try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)
            guard self.take == take else { return }
            self.duration = d.isFinite ? d : 0
            if let rate, rate > 0 { self.fps = Double(rate) }
        }
    }

    func unload() {
        stopEmulation()
        player.pause()
        player.replaceCurrentItem(with: nil)
        take = nil
        time = 0
        duration = 0
    }

    func play() {
        guard isLoaded else { return }
        stopEmulation()
        if isAtEnd { seek(to: 0) }
        player.rate = 1
    }

    func pause() {
        stopEmulation()
        player.pause()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func step(frames: Int) {
        pause()
        seek(to: min(max(0, time + Double(frames) / fps), duration))
    }

    // MARK: Scrubbing

    func beginScrub() {
        isScrubbing = true
    }

    func scrub(to seconds: Double) {
        time = min(max(0, seconds), duration)
        seek(to: time)
    }

    func endScrub() {
        isScrubbing = false
    }

    func seek(to seconds: Double) {
        time = seconds
        seekTarget = seconds
        guard !isSeeking else { return }
        performSeek()
    }

    private func performSeek() {
        guard let target = seekTarget else { return }
        seekTarget = nil
        isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSeeking = false
                if self.seekTarget != nil { self.performSeek() }
            }
        }
    }

    /// HH:MM:SS:FF at the clip's frame rate.
    func timecode(_ seconds: Double) -> String {
        let fpsInt = max(1, Int(fps.rounded()))
        let totalFrames = Int((max(0, seconds) * fps).rounded(.down))
        let f = totalFrames % fpsInt
        let s = totalFrames / fpsInt
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f)
    }
}

// MARK: - Views

/// Video surface without controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct MonitorView: View {
    @ObservedObject var monitor: MonitorPlayer
    let number: Int
    let isLatest: Bool
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottomLeading) {
                Color.black
                if monitor.isLoaded {
                    PlayerSurface(player: monitor.player)
                    if let speed = speedLabel {
                        Text(speed)
                            .font(.system(.callout, design: .rounded).weight(.heavy).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(MonitorColor.color(number)))
                            .padding(10)
                            .transition(.opacity)
                    }
                } else {
                    VStack(spacing: 10) {
                        Text("\(number)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("Take links auswählen und **\(number)** drücken")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: speedLabel)
            transport
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(Rectangle().strokeBorder(MonitorColor.color(number).opacity(0.75), lineWidth: 2.5))
    }

    /// "2×", "◀ 1×" … while shuttling (nothing at normal speed).
    private var speedLabel: String? {
        let r = monitor.shuttleRate
        guard monitor.isPlaying, r != 0, r != 1 else { return nil }
        let value = abs(r) == abs(r).rounded() ? String(Int(abs(r))) : String(format: "%.1f", abs(r))
        return (r < 0 ? "◀ " : "▶ ") + value + "×"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(number == 2 ? Color.black : .white)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(MonitorColor.color(number)))
            if let take = monitor.take {
                Text(take.name).font(.callout.weight(.medium)).lineLimit(1)
                if isLatest {
                    Text("LETZTER TAKE").font(.caption2.weight(.bold)).foregroundStyle(.green)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().strokeBorder(Color.green.opacity(0.6)))
                }
            } else {
                Text("Monitor \(number)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                monitor.isMuted.toggle()
            } label: {
                Image(systemName: monitor.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(monitor.isMuted ? .secondary : .primary)
            }
            .buttonStyle(.borderless)
            .help(monitor.isMuted ? "Ton einschalten" : "Ton stummschalten")
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Monitor 2 schließen")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var transport: some View {
        VStack(spacing: 6) {
            Scrubber(monitor: monitor)
                .frame(height: 22)
            HStack(spacing: 14) {
                Button { monitor.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Ein Bild zurück")
                Button { monitor.togglePlay() } label: {
                    Image(systemName: monitor.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .help("Abspielen / Pause (Leertaste: beide Monitore · J / K / L: rückwärts, Stopp, vorwärts – mehrmals für 2×, 4×, 8×)")
                Button { monitor.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Ein Bild vor")
                Spacer()
                Text(monitor.timecode(monitor.time))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                Text("/ " + monitor.timecode(monitor.duration))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!monitor.isLoaded)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Timeline with a freely draggable playhead (click anywhere to jump).
struct Scrubber: View {
    @ObservedObject var monitor: MonitorPlayer

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let progress = monitor.duration > 0 ? min(1, max(0, monitor.time / monitor.duration)) : 0
            let x = w * progress
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(0, x), height: 6)
                // Playhead
                VStack(spacing: 0) {
                    Triangle().fill(Color.primary).frame(width: 11, height: 7)
                    Rectangle().fill(Color.primary).frame(width: 2, height: 15)
                }
                .offset(x: x - 5.5)
                .shadow(color: .black.opacity(0.25), radius: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !monitor.isScrubbing { monitor.pause(); monitor.beginScrub() }
                        monitor.scrub(to: Double(min(max(0, v.location.x), w) / max(w, 1)) * monitor.duration)
                    }
                    .onEnded { _ in monitor.endScrub() }
            )
        }
        .opacity(monitor.isLoaded ? 1 : 0.4)
        .allowsHitTesting(monitor.isLoaded)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
