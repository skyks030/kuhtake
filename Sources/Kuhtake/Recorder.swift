import AVFoundation
import CoreImage

enum RecorderError: LocalizedError {
    case noFrames
    case writerFailed(String)
    var errorDescription: String? {
        switch self {
        case .noFrames: return "Es wurden keine Bilder aufgezeichnet."
        case .writerFailed(let s): return "Datei konnte nicht geschrieben werden: \(s)"
        }
    }
}

/// Writes captured frames into a movie file with a constant frame rate.
/// Frames are re-timed onto the frame grid; short gaps (static content) are filled with the previous frame.
final class Recorder: CaptureSink {
    struct Config {
        var container: ContainerFormat
        var codec: VideoCodecOption
        var resolution: ResolutionMode
        var frameRate: FrameRateOption
        var bitrateMbps: Double
        var audio: Bool
        /// Start timecode (frames since midnight at `frameRate`'s timecode base), asked for at the first frame.
        /// nil = no timecode track.
        var timecode: (() -> Int)?
    }

    struct Result {
        let url: URL
        let duration: TimeInterval
    }

    let url: URL
    private let cfg: Config
    private let queue = DispatchQueue(label: "kuhtake.recorder", qos: .userInitiated)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timecodeInput: AVAssetWriterInput?
    private var timecodeFormat: CMTimeCodeFormatDescription?
    private var startTimecode = 0
    private var outSize: CGSize = .zero
    private var startTime: CMTime = .invalid
    private var lastIndex = -1
    private var lastBuffer: CVPixelBuffer?
    private var finishing = false
    private var failure: Error?

    init(url: URL, config: Config) {
        self.url = url
        self.cfg = config
    }

    // MARK: CaptureSink (called from capture queues)

    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        queue.async { self.handleVideo(pixelBuffer, pts: pts) }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard cfg.audio else { return }
        queue.async { self.handleAudio(sampleBuffer) }
    }

    // MARK: Writing

    private func frameTime(_ index: Int) -> CMTime {
        CMTimeAdd(startTime, CMTimeMultiply(cfg.frameRate.frameDuration, multiplier: Int32(index)))
    }

    private func handleVideo(_ pb: CVPixelBuffer, pts: CMTime) {
        guard !finishing, failure == nil else { return }
        if writer == nil {
            do { try setUp(sourceWidth: CVPixelBufferGetWidth(pb), sourceHeight: CVPixelBufferGetHeight(pb), at: pts) } catch {
                failure = error
                return
            }
        }
        guard let writer, writer.status == .writing, let videoInput, let adaptor else {
            if let w = writer, w.status == .failed { failure = w.error }
            return
        }

        let frameSeconds = cfg.frameRate.frameDuration.seconds
        let index = Int((CMTimeSubtract(pts, startTime).seconds / frameSeconds).rounded())
        guard index > lastIndex else { return }
        guard let rendered = render(pb, pool: adaptor.pixelBufferPool) else { return }

        // Fill short gaps so the file stays constant-frame-rate.
        if let previous = lastBuffer {
            let maxFill = Int(cfg.frameRate.nominal * 5)
            var filled = 0
            while lastIndex + 1 < index, filled < maxFill, videoInput.isReadyForMoreMediaData,
                  let copy = render(previous, pool: adaptor.pixelBufferPool) {
                // The encoder needs a distinct buffer per frame; re-appending the same one fails the writer.
                guard adaptor.append(copy, withPresentationTime: frameTime(lastIndex + 1)) else { return }
                appendTimecode(lastIndex + 1)
                lastIndex += 1
                filled += 1
            }
        }
        if videoInput.isReadyForMoreMediaData, adaptor.append(rendered, withPresentationTime: frameTime(index)) {
            appendTimecode(index)
            lastIndex = index
            lastBuffer = rendered
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard !finishing, let writer, writer.status == .writing, let audioInput, startTime.isValid else { return }
        guard CMTimeCompare(sb.presentationTimeStamp, startTime) >= 0 else { return }
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sb)
        }
    }

    private func setUp(sourceWidth: Int, sourceHeight: Int, at pts: CMTime) throws {
        if let fixed = cfg.resolution.fixedSize {
            outSize = fixed
        } else {
            outSize = CGSize(width: sourceWidth & ~1, height: sourceHeight & ~1)
        }
        let w = try AVAssetWriter(outputURL: url, fileType: cfg.container.fileType)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: cfg.codec.avCodec,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !cfg.codec.isProRes {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(cfg.bitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: Int(cfg.frameRate.nominal.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int(cfg.frameRate.nominal.rounded()) * 2,
                AVVideoAllowFrameReorderingKey: false,
            ]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        guard w.canAdd(vIn) else { throw RecorderError.writerFailed("Video-Einstellungen werden nicht unterstützt") }
        w.add(vIn)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outSize.width),
            kCVPixelBufferHeightKey as String: Int(outSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])

        if cfg.audio {
            let audioSettings: [String: Any]
            if cfg.codec.isProRes {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            } else {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000,
                ]
            }
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) {
                w.add(aIn)
                audioInput = aIn
            }
        }

        if let timecode = cfg.timecode {
            addTimecodeTrack(to: w, video: vIn, start: timecode())
        }

        guard w.startWriting() else {
            throw RecorderError.writerFailed(w.error?.localizedDescription ?? "startWriting")
        }
        w.startSession(atSourceTime: pts)
        startTime = pts
        writer = w
        videoInput = vIn
        self.adaptor = adaptor
    }

    // MARK: Timecode

    /// QuickTime timecode track ('tmcd'), linked to the video track – NLEs (Resolve, Premiere, Avid, FCP) read the
    /// clip's start timecode from it. MPEG-4 files can't carry one; they are written without.
    private func addTimecodeTrack(to w: AVAssetWriter, video: AVAssetWriterInput, start: Int) {
        let quanta = UInt32(max(1, Int(cfg.frameRate.nominal.rounded())))
        var format: CMTimeCodeFormatDescription?
        guard CMTimeCodeFormatDescriptionCreate(allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                                                frameDuration: cfg.frameRate.frameDuration, frameQuanta: quanta,
                                                flags: kCMTimeCodeFlag_24HourMax, extensions: nil,
                                                formatDescriptionOut: &format) == noErr, let format else { return }
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else { return }
        w.add(input)
        video.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
        timecodeInput = input
        timecodeFormat = format
        startTimecode = start
    }

    /// One timecode sample per video frame, right after it (keeps both tracks interleaved).
    private func appendTimecode(_ index: Int) {
        guard let input = timecodeInput, let format = timecodeFormat, input.isReadyForMoreMediaData else { return }
        let dayFrames = 24 * 3600 * max(1, Int(cfg.frameRate.nominal.rounded()))
        var value = Int32((startTimecode + index) % dayFrames).bigEndian
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: 4,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferReplaceDataBytes(with: &value, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4) == noErr
        else { return }
        var timing = CMSampleTimingInfo(duration: cfg.frameRate.frameDuration, presentationTimeStamp: frameTime(index),
                                        decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        input.append(sample)
    }

    /// Scales the source aspect-fit into the output size (black bars where needed).
    private func render(_ source: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        let W = outSize.width, H = outSize.height
        var image = CIImage(cvPixelBuffer: source)
        let sw = image.extent.width, sh = image.extent.height
        if sw != W || sh != H {
            let s = min(W / sw, H / sh)
            image = image
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: ((W - sw * s) / 2).rounded(), y: ((H - sh * s) / 2).rounded()))
        }
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let composed = image.composited(over: CIImage(color: .black).cropped(to: canvas))
        ci.render(composed, to: out, bounds: canvas, colorSpace: colorSpace)
        return out
    }

    // MARK: Finish

    func finish(completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        queue.async {
            self.finishing = true
            guard let writer = self.writer, writer.status == .writing, self.lastIndex >= 0 else {
                self.writer?.cancelWriting()
                try? FileManager.default.removeItem(at: self.url)
                let error = self.failure ?? self.writer?.error ?? RecorderError.noFrames
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let end = self.frameTime(self.lastIndex + 1)
            let duration = CMTimeSubtract(end, self.startTime).seconds
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.timecodeInput?.markAsFinished()
            writer.endSession(atSourceTime: end)
            writer.finishWriting {
                let result: Swift.Result<Result, Error> = writer.status == .completed
                    ? .success(Result(url: self.url, duration: duration))
                    : .failure(writer.error ?? RecorderError.writerFailed("finishWriting"))
                self.lastBuffer = nil
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}
