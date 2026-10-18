import AVFoundation
import CoreMedia
import VideoToolbox

enum StreamVideoCodec: String {
    case h264 = "H.264", hevc = "HEVC"

    func nalType(_ nal: Data) -> Int {
        guard let b = nal.first else { return -1 }
        return self == .h264 ? Int(b & 0x1f) : Int((b >> 1) & 0x3f)
    }

    /// SPS / PPS (and VPS for HEVC).
    func isParameterSet(_ type: Int) -> Bool {
        self == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
    }

    func isKeyframe(_ type: Int) -> Bool {
        self == .h264 ? type == 5 : (16...21).contains(type)
    }

    /// Access unit delimiters carry nothing the decoder needs.
    func isDelimiter(_ type: Int) -> Bool { self == .h264 ? type == 9 : type == 35 }
}

enum NALUnits {
    /// Splits an Annex-B byte stream (00 00 01 / 00 00 00 01 start codes) into NAL units.
    static func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(Int, Int)] = []   // (start code position, payload start)
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 4 <= b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        var nals: [Data] = []
        for (n, s) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1].0 : b.count
            while end > s.1, b[end - 1] == 0 { end -= 1 }   // trailing zero bytes
            if end > s.1 { nals.append(Data(b[s.1..<end])) }
        }
        return nals
    }

    static func annexB(_ nals: [Data]) -> Data {
        var out = Data()
        for n in nals { out.append(contentsOf: [0, 0, 0, 1]); out.append(n) }
        return out
    }

    /// 4-byte big-endian length prefixes (what VideoToolbox / MP4 expect).
    static func avcc(_ nals: [Data]) -> Data {
        var out = Data()
        for n in nals {
            var len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(n)
        }
        return out
    }

    /// The other way round (encoder output).
    static func fromAVCC(_ data: Data, lengthSize: Int = 4) -> [Data] {
        var nals: [Data] = []
        let b = [UInt8](data)
        var i = 0
        while i + lengthSize <= b.count {
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(b[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= b.count else { break }
            nals.append(Data(b[i..<(i + len)]))
            i += len
        }
        return nals
    }
}

/// Maps a stream's own clock (RTP / PES timestamps in seconds) onto the host clock, which the recorder and the
/// rest of the app use. Re-anchors if the two drift apart (encoder restarted, timestamp jump).
final class StreamClock {
    private var anchor: (source: Double, host: Double)?
    private let lock = NSLock()

    static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func pts(forSource t: Double) -> CMTime {
        let now = Self.hostNow
        let host: Double = lock.withLock {
            if let a = anchor {
                let mapped = a.host + (t - a.source)
                if abs(mapped - now) < 1.0 { return mapped }
            }
            anchor = (t, now)
            return now
        }
        return CMTime(seconds: host, preferredTimescale: 90_000)
    }

    func reset() { lock.withLock { anchor = nil } }
}

// MARK: - Video decoding

/// H.264 / HEVC access units → BGRA pixel buffers via VideoToolbox. Parameter sets come from the SDP or in-band;
/// the session is rebuilt whenever they change (resolution switch on the encoder).
final class VideoStreamDecoder {
    private(set) var codec: StreamVideoCodec?
    private var parameterSets: [Int: Data] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let clock: StreamClock
    private let output: (CVPixelBuffer, CMTime) -> Void
    private let log = StreamLog.shared
    private var waitingLogged = false
    /// After the session is (re)built, pictures before the first keyframe only produce decoder errors.
    /// Encoders with intra refresh never send one, so give up waiting after a while.
    private var awaitingKeyframe = true
    private var skippedBeforeKeyframe = 0

    // Statistics (read from anywhere, roughly).
    private(set) var decodedFrames = 0
    private(set) var decodeErrors = 0
    private(set) var droppedWaitingForParameters = 0
    private(set) var droppedWaitingForKeyframe = 0
    private(set) var receivedUnits = 0
    private(set) var receivedBytes = 0
    private(set) var keyframes = 0
    private(set) var dimensions: CMVideoDimensions?

    init(clock: StreamClock, output: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.clock = clock
        self.output = output
    }

    var summary: String {
        var s = codec?.rawValue ?? "?"
        if let d = dimensions { s += " \(d.width)×\(d.height)" }
        return s
    }

    /// Parameter sets announced out of band (SDP sprop-parameter-sets).
    func setParameterSets(_ nals: [Data], codec: StreamVideoCodec) {
        self.codec = codec
        for n in nals { storeParameterSet(n, codec: codec) }
    }

    private func storeParameterSet(_ nal: Data, codec: StreamVideoCodec) {
        let type = codec.nalType(nal)
        if parameterSets[type] != nal {
            parameterSets[type] = nal
            invalidate()
        }
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        awaitingKeyframe = true
        skippedBeforeKeyframe = 0
    }

    func reset() {
        invalidate()
        parameterSets = [:]
        waitingLogged = false
    }

    /// One picture's NAL units with its time on the stream clock (seconds).
    func decode(_ nals: [Data], codec: StreamVideoCodec, time: Double) {
        if self.codec != codec { self.codec = codec; reset() }
        receivedUnits += 1
        var slices: [Data] = []
        var key = false
        for n in nals where !n.isEmpty {
            receivedBytes += n.count
            let type = codec.nalType(n)
            if codec.isParameterSet(type) { storeParameterSet(n, codec: codec); continue }
            if codec.isDelimiter(type) { continue }
            if codec.isKeyframe(type) { key = true }
            slices.append(n)
        }
        if key { keyframes += 1 }
        guard !slices.isEmpty else { return }
        guard ensureSession(codec: codec) else {
            droppedWaitingForParameters += 1
            if !waitingLogged {
                waitingLogged = true
                log.log("Warte auf Parameter-Sets (SPS/PPS\(codec == .hevc ? "/VPS" : "")) – vorhandene NAL-Typen: \(parameterSets.keys.sorted())", "decoder")
            }
            return
        }
        guard let formatDescription, let session else { return }
        if awaitingKeyframe {
            if !key, skippedBeforeKeyframe < 90 {
                skippedBeforeKeyframe += 1
                droppedWaitingForKeyframe += 1
                return
            }
            awaitingKeyframe = false
            if skippedBeforeKeyframe > 0 {
                log.log(key ? "Erster Keyframe nach \(skippedBeforeKeyframe) übersprungenen Bildern"
                            : "Kein Keyframe nach \(skippedBeforeKeyframe) Bildern (Intra-Refresh?) – dekodiere trotzdem", "decoder")
            }
        }
        let payload = NALUnits.avcc(slices)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return }
        payload.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        let pts = clock.pts(forSource: time)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback],
                                                       infoFlagsOut: nil) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            if status == noErr, let image {
                self.decodedFrames += 1
                self.output(image, pts)
            } else if status != noErr {
                self.decodeErrors += 1
                if self.decodeErrors <= 5 || self.decodeErrors % 100 == 0 {
                    self.log.log("Dekodierfehler \(status) (bisher \(self.decodeErrors))", "decoder")
                }
            }
        }
        if status == kVTInvalidSessionErr {
            log.log("Decoder-Session ungültig – wird neu erstellt", "decoder")
            invalidate()
        } else if status != noErr {
            decodeErrors += 1
            if decodeErrors <= 5 { log.log("VTDecompressionSessionDecodeFrame: \(status)", "decoder") }
        }
    }

    private func ensureSession(codec: StreamVideoCodec) -> Bool {
        if session != nil { return true }
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps = parameterSets[7], let pps = parameterSets[8] else { return false }
            sets = [sps, pps]
        case .hevc:
            guard let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] else { return false }
            sets = [vps, sps, pps]
        }
        guard let fmt = Self.formatDescription(codec: codec, sets: sets) else {
            log.log("Formatbeschreibung aus Parameter-Sets fehlgeschlagen", "decoder")
            return false
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let spec: [String: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &s)
        guard status == noErr, let s else {
            log.log("VTDecompressionSessionCreate fehlgeschlagen: \(status)", "decoder")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        formatDescription = fmt
        dimensions = CMVideoFormatDescriptionGetDimensions(fmt)
        waitingLogged = false
        log.log("Decoder bereit: \(codec.rawValue) \(dimensions!.width)×\(dimensions!.height)", "decoder")
        return true
    }

    static func formatDescription(codec: StreamVideoCodec, sets: [Data]) -> CMVideoFormatDescription? {
        let buffers = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fmt: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }
}

// MARK: - AAC

/// MPEG-4 AudioSpecificConfig (object type, sample rate, channels).
struct AACConfig: Equatable {
    static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    var objectType: Int
    var sampleRate: Double
    var channels: Int
    var asc: Data

    init?(asc: Data) {
        let b = [UInt8](asc)
        guard b.count >= 2 else { return nil }
        objectType = Int(b[0] >> 3)
        let srIndex = Int((b[0] & 0x07) << 1 | b[1] >> 7)
        if srIndex == 15 {
            guard b.count >= 5 else { return nil }
            sampleRate = Double((Int(b[1] & 0x7f) << 17) | (Int(b[2]) << 9) | (Int(b[3]) << 1) | Int(b[4] >> 7))
            channels = Int((b[4] >> 3) & 0x0f)
        } else {
            guard srIndex < Self.sampleRates.count else { return nil }
            sampleRate = Self.sampleRates[srIndex]
            channels = Int((b[1] >> 3) & 0x0f)
        }
        if channels == 0 { channels = 2 }
        self.asc = asc
    }

    /// From an ADTS header (MPEG-TS audio).
    init?(adtsProfile profile: Int, srIndex: Int, channels: Int) {
        guard srIndex < Self.sampleRates.count else { return nil }
        let object = profile + 1
        let ch = max(1, channels)
        let v = UInt16(object << 11 | srIndex << 7 | ch << 3)
        self.init(asc: Data([UInt8(v >> 8), UInt8(v & 0xff)]))
    }

    static func fromHex(_ hex: String) -> AACConfig? {
        var data = Data()
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let v = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            data.append(v)
        }
        return AACConfig(asc: data)
    }

    var summary: String { "AAC \(Int(sampleRate)) Hz, \(channels) Kanäle" }
}

/// Raw AAC frames → interleaved Float32 PCM sample buffers (what the recorder and meters take).
final class AACDecoder {
    let config: AACConfig
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private(set) var decodedFrames = 0
    private(set) var errors = 0

    init?(config: AACConfig) {
        self.config = config
        var asbd = AudioStreamBasicDescription(mSampleRate: config.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: UInt32(config.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(config.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &asbd),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: config.sampleRate,
                                            channels: AVAudioChannelCount(config.channels), interleaved: true) else { return nil }
        inFormat.magicCookie = config.asc
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        self.inFormat = inFormat
        self.outFormat = outFormat
        self.converter = converter
    }

    func decode(_ frame: Data, pts: CMTime) -> CMSampleBuffer? {
        guard !frame.isEmpty else { return nil }
        let compressed = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: frame.count)
        frame.withUnsafeBytes { raw in compressed.data.copyMemory(from: raw.baseAddress!, byteCount: frame.count) }
        compressed.byteLength = UInt32(frame.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(frame.count))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 2048) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, pcm.frameLength > 0 else {
            if status == .error { errors += 1 }
            return nil
        }
        decodedFrames += 1
        return Self.sampleBuffer(pcm, pts: pts)
    }

    static func sampleBuffer(_ pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        let abl = pcm.audioBufferList.pointee
        guard let data = abl.mBuffers.mData else { return nil }
        let length = Int(abl.mBuffers.mDataByteSize)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        let rate = pcm.format.sampleRate
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: pcm.format.formatDescription, sampleCount: CMItemCount(pcm.frameLength),
            presentationTimeStamp: CMTimeConvertScale(pts, timescale: CMTimeScale(rate), method: .roundHalfAwayFromZero),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}

// MARK: - Encoding (simulator)

/// Test-pattern pictures → H.264 (low latency, no B-frames), like a Teradek encoder would send.
final class H264TestEncoder {
    struct Frame {
        let nals: [Data]
        let isKeyframe: Bool
        let pts: CMTime
    }

    private var session: VTCompressionSession?
    private let onFrame: (Frame) -> Void
    private(set) var sps: Data?
    private(set) var pps: Data?

    init?(width: Int, height: Int, fps: Int, bitrate: Int, onFrame: @escaping (Frame) -> Void) {
        self.onFrame = onFrame
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { return nil }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, let block = sample.dataBuffer else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if let fmt = sample.formatDescription {
                var count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                var sets: [Data] = []
                for i in 0..<count {
                    var p: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                          parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                          nalUnitHeaderLengthOut: nil) == noErr, let p {
                        sets.append(Data(bytes: p, count: size))
                    }
                }
                if sets.count >= 2 { self.sps = sets[0]; self.pps = sets[1] }
            }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { return }
            let data = Data(bytes: pointer, count: length)
            var nals = NALUnits.fromAVCC(data)
            if !notSync, let sps = self.sps, let pps = self.pps { nals.insert(contentsOf: [sps, pps], at: 0) }
            self.onFrame(Frame(nals: nals, isKeyframe: !notSync, pts: sample.presentationTimeStamp))
        }
    }
}

/// PCM → AAC-LC packets of 1024 samples (simulator audio).
final class AACTestEncoder {
    let config: AACConfig
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat

    init?(sampleRate: Double = 48_000, channels: Int = 2) {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: false) else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &asbd), let conv = AVAudioConverter(from: pcm, to: aac) else { return nil }
        conv.bitRate = 128_000
        pcmFormat = pcm
        aacFormat = aac
        converter = conv
        let srIndex = AACConfig.sampleRates.firstIndex(of: sampleRate) ?? 3
        guard let cfg = AACConfig(adtsProfile: 1, srIndex: srIndex, channels: channels) else { return nil }
        config = cfg
    }

    var frameCount: AVAudioFrameCount { 1024 }

    /// `fill(channel, sampleIndex)` gives each sample; returns the AAC packets that came out.
    func encode(fill: (Int, Int) -> Float) -> [Data] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else { return [] }
        buffer.frameLength = frameCount
        for ch in 0..<Int(pcmFormat.channelCount) {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frameCount) { p[i] = fill(ch, i) }
        }
        let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        var packets: [Data] = []
        for i in 0..<Int(out.packetCount) {
            guard let d = out.packetDescriptions?[i] else { continue }
            packets.append(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
        }
        return packets
    }
}
