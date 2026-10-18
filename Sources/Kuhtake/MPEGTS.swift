import Foundation

/// MPEG transport stream → H.264 / HEVC pictures and AAC (ADTS) frames. Takes raw TS, or TS inside RTP (UDP from
/// encoders in "MPEG-TS" mode). Video and audio share the 90 kHz PES clock.
final class TSDemuxer {
    struct Stats {
        var packets = 0
        var syncLosses = 0
        var continuityErrors = 0
        var streams: [Int: UInt8] = [:]    // pid → stream type
        var videoUnits = 0
        var audioFrames = 0
        var rtpWrapped = false
    }

    private let output: StreamMediaOutput
    private let log = StreamLog.shared
    private var remainder = Data()
    private var pmtPID: Int?
    private var videoPID: Int?
    private var videoCodec: StreamVideoCodec?
    private var audioPID: Int?
    private var pes: [Int: Data] = [:]
    private var continuity: [Int: UInt8] = [:]
    private var audioConfig: AACConfig?
    private(set) var stats = Stats()

    init(output: StreamMediaOutput) { self.output = output }

    /// A UDP datagram or a chunk of a TCP stream.
    func feed(_ data: Data, datagram: Bool = false) {
        var d = data
        // RTP-wrapped TS (payload type 33): skip the RTP header.
        if datagram, d.count >= 12, d[d.startIndex] != 0x47, d[d.startIndex] >> 6 == 2, let p = RTPPacket(d) {
            if !stats.rtpWrapped { log.log("MPEG-TS kommt in RTP verpackt (PT \(p.payloadType))", "ts") }
            stats.rtpWrapped = true
            d = p.payload
        }
        var b = remainder.isEmpty ? [UInt8](d) : [UInt8](remainder + d)
        remainder = Data()
        var i = 0
        while i + 188 <= b.count {
            if b[i] != 0x47 {
                // Resync: next position with sync bytes 188 apart.
                stats.syncLosses += 1
                var found = false
                var j = i + 1
                while j + 188 < b.count {
                    if b[j] == 0x47, b[j + 188] == 0x47 { found = true; break }
                    j += 1
                }
                if !found { i = max(i, b.count - 187); break }
                i = j
            }
            packet(b, at: i)
            i += 188
        }
        if i < b.count { remainder = Data(b[i...]) }
        b = []
    }

    private func packet(_ b: [UInt8], at o: Int) {
        stats.packets += 1
        let pusi = b[o + 1] & 0x40 != 0
        let pid = Int(b[o + 1] & 0x1f) << 8 | Int(b[o + 2])
        let afc = (b[o + 3] >> 4) & 0x3
        let cc = b[o + 3] & 0x0f
        if afc & 1 != 0 {
            if let last = continuity[pid], (last + 1) & 0x0f != cc, last != cc { stats.continuityErrors += 1 }
            continuity[pid] = cc
        }
        var p = o + 4
        if afc & 2 != 0 { p += 1 + Int(b[o + 4]) }
        guard afc & 1 != 0, p < o + 188 else { return }
        let payload = Array(b[p..<(o + 188)])

        if pid == 0 { parsePAT(payload, pusi: pusi); return }
        if pid == pmtPID { parsePMT(payload, pusi: pusi); return }
        guard pid == videoPID || pid == audioPID else { return }
        if pusi {
            if let previous = pes[pid] { finishPES(previous, pid: pid) }
            pes[pid] = Data(payload)
        } else if pes[pid] != nil {
            pes[pid]!.append(contentsOf: payload)
        }
        // Known PES length: hand it over as soon as it is complete (keeps audio latency low).
        if let data = pes[pid], data.count >= 6 {
            let length = Int(data[data.startIndex + 4]) << 8 | Int(data[data.startIndex + 5])
            if length > 0, data.count >= 6 + length {
                finishPES(data.prefix(6 + length), pid: pid)
                pes[pid] = nil
            }
        }
    }

    private func section(_ payload: [UInt8], pusi: Bool) -> [UInt8]? {
        guard pusi, !payload.isEmpty else { return nil }
        let start = 1 + Int(payload[0])
        guard start + 3 <= payload.count else { return nil }
        let length = Int(payload[start + 1] & 0x0f) << 8 | Int(payload[start + 2])
        guard start + 3 + length <= payload.count else { return nil }
        return Array(payload[start..<(start + 3 + length)])
    }

    private func parsePAT(_ payload: [UInt8], pusi: Bool) {
        guard let s = section(payload, pusi: pusi), s.count >= 12 else { return }
        var i = 8
        while i + 4 <= s.count - 4 {
            let program = Int(s[i]) << 8 | Int(s[i + 1])
            let pid = Int(s[i + 2] & 0x1f) << 8 | Int(s[i + 3])
            if program != 0 {
                if pmtPID != pid { log.log("PAT: Programm \(program) → PMT-PID \(pid)", "ts") }
                pmtPID = pid
                return
            }
            i += 4
        }
    }

    private func parsePMT(_ payload: [UInt8], pusi: Bool) {
        guard let s = section(payload, pusi: pusi), s.count >= 16 else { return }
        let infoLength = Int(s[10] & 0x0f) << 8 | Int(s[11])
        var i = 12 + infoLength
        var streams: [Int: UInt8] = [:]
        while i + 5 <= s.count - 4 {
            let type = s[i]
            let pid = Int(s[i + 1] & 0x1f) << 8 | Int(s[i + 2])
            let esInfo = Int(s[i + 3] & 0x0f) << 8 | Int(s[i + 4])
            streams[pid] = type
            i += 5 + esInfo
        }
        guard streams != stats.streams else { return }
        stats.streams = streams
        log.log("PMT: " + streams.sorted { $0.key < $1.key }.map { "PID \($0.key) Typ 0x\(String(format: "%02x", $0.value)) (\(Self.typeName($0.value)))" }.joined(separator: ", "), "ts")
        videoPID = nil
        audioPID = nil
        for (pid, type) in streams.sorted(by: { $0.key < $1.key }) {
            switch type {
            case 0x1b where videoPID == nil: videoPID = pid; videoCodec = .h264
            case 0x24 where videoPID == nil: videoPID = pid; videoCodec = .hevc
            case 0x0f where audioPID == nil: audioPID = pid
            default: break
            }
        }
        if videoPID == nil { log.log("Kein H.264-/HEVC-Video im Transportstrom", "ts") }
    }

    static func typeName(_ t: UInt8) -> String {
        switch t {
        case 0x01, 0x02: return "MPEG-2 Video"
        case 0x03, 0x04: return "MPEG Audio"
        case 0x0f: return "AAC ADTS"
        case 0x11: return "AAC LATM"
        case 0x1b: return "H.264"
        case 0x24: return "HEVC"
        case 0x06: return "Private (z. B. Untertitel/Opus)"
        case 0x81: return "AC-3"
        case 0x15: return "Metadaten"
        default: return "?"
        }
    }

    private func finishPES(_ data: Data, pid: Int) {
        let b = [UInt8](data)
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
        let headerLength = Int(b[8])
        guard 9 + headerLength <= b.count else { return }
        var time: Double?
        if b[7] & 0x80 != 0, headerLength >= 5 {
            let pts = (Int64(b[9] >> 1) & 0x07) << 30 | Int64(b[10]) << 22 | (Int64(b[11]) >> 1) << 15 | Int64(b[12]) << 7 | Int64(b[13]) >> 1
            time = Double(pts) / 90_000
        }
        let payload = Data(b[(9 + headerLength)...])
        guard let t = time else { return }
        if pid == videoPID, let codec = videoCodec {
            stats.videoUnits += 1
            output.video(NALUnits.splitAnnexB(payload), codec: codec, time: t)
        } else if pid == audioPID {
            adts(payload, time: t)
        }
    }

    private func adts(_ data: Data, time: Double) {
        let b = [UInt8](data)
        var i = 0
        var n = 0
        while i + 7 <= b.count {
            guard b[i] == 0xff, b[i + 1] & 0xf0 == 0xf0 else { i += 1; continue }
            let protectionAbsent = b[i + 1] & 1 != 0
            let profile = Int(b[i + 2] >> 6)
            let srIndex = Int((b[i + 2] >> 2) & 0x0f)
            let channels = Int((b[i + 2] & 1) << 2 | b[i + 3] >> 6)
            let length = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard length > header, i + length <= b.count else { break }
            if let cfg = AACConfig(adtsProfile: profile, srIndex: srIndex, channels: channels), cfg != audioConfig {
                audioConfig = cfg
                output.audioConfig(cfg)
            }
            let rate = audioConfig?.sampleRate ?? 48_000
            stats.audioFrames += 1
            output.aac(Data(b[(i + header)..<(i + length)]), time: time + Double(n * 1024) / rate)
            n += 1
            i += length
        }
    }
}

/// H.264 (+ AAC) → MPEG-TS packets, for the simulator's "MPEG-TS over UDP" mode.
final class TSMuxer {
    static let videoPID = 0x100, audioPID = 0x101, pmtPID = 0x1000
    private var cc: [Int: UInt8] = [:]
    private var packetsSincePSI = 1000

    /// Returns 188-byte packets.
    func video(_ nals: [Data], pts: Double, keyframe: Bool) -> [Data] {
        var out: [Data] = []
        if keyframe || packetsSincePSI > 400 { out += psi() }
        var es = Data([0, 0, 0, 1, 0x09, 0xf0])   // access unit delimiter
        es.append(NALUnits.annexB(nals))
        out += pes(es, pid: Self.videoPID, streamID: 0xe0, pts: pts, pcr: pts, bounded: false)
        return out
    }

    func audio(_ aac: Data, config: AACConfig, pts: Double) -> [Data] {
        let srIndex = AACConfig.sampleRates.firstIndex(of: config.sampleRate) ?? 3
        let length = aac.count + 7
        var h = [UInt8](repeating: 0, count: 7)
        h[0] = 0xff
        h[1] = 0xf1
        h[2] = UInt8(((config.objectType - 1) & 0x3) << 6 | (srIndex & 0x0f) << 2 | (config.channels >> 2) & 1)
        h[3] = UInt8((config.channels & 3) << 6 | (length >> 11) & 0x3)
        h[4] = UInt8((length >> 3) & 0xff)
        h[5] = UInt8((length & 7) << 5 | 0x1f)
        h[6] = 0xfc
        return pes(Data(h) + aac, pid: Self.audioPID, streamID: 0xc0, pts: pts, pcr: nil, bounded: true)
    }

    private func psi() -> [Data] {
        packetsSincePSI = 0
        // PAT: program 1 → PMT
        var pat: [UInt8] = [0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00, 0x00, 0x01,
                            UInt8(0xe0 | (Self.pmtPID >> 8)), UInt8(Self.pmtPID & 0xff)]
        pat += Self.crc(pat)
        // PMT: H.264 + AAC, PCR on the video PID
        var pmt: [UInt8] = [0x02, 0xb0, 0x17, 0x00, 0x01, 0xc1, 0x00, 0x00,
                            UInt8(0xe0 | (Self.videoPID >> 8)), UInt8(Self.videoPID & 0xff), 0xf0, 0x00,
                            0x1b, UInt8(0xe0 | (Self.videoPID >> 8)), UInt8(Self.videoPID & 0xff), 0xf0, 0x00,
                            0x0f, UInt8(0xe0 | (Self.audioPID >> 8)), UInt8(Self.audioPID & 0xff), 0xf0, 0x00]
        pmt += Self.crc(pmt)
        return [section(pat, pid: 0), section(pmt, pid: Self.pmtPID)]
    }

    private func section(_ s: [UInt8], pid: Int) -> Data {
        var p: [UInt8] = [0x47, UInt8(0x40 | (pid >> 8)), UInt8(pid & 0xff), 0x10 | nextCC(pid), 0x00]
        p += s
        p += [UInt8](repeating: 0xff, count: 188 - p.count)
        return Data(p)
    }

    private func nextCC(_ pid: Int) -> UInt8 {
        let v = (cc[pid, default: 0x0f] &+ 1) & 0x0f
        cc[pid] = v
        return v
    }

    private func pes(_ es: Data, pid: Int, streamID: UInt8, pts: Double, pcr: Double?, bounded: Bool) -> [Data] {
        let ticks = Int64((pts * 90_000).rounded()) & 0x1_ffff_ffff
        var header: [UInt8] = [0, 0, 1, streamID, 0, 0, 0x80, 0x80, 5]
        header += [UInt8(0x21 | ((ticks >> 29) & 0x0e)), UInt8((ticks >> 22) & 0xff), UInt8(((ticks >> 14) & 0xfe) | 1),
                   UInt8((ticks >> 7) & 0xff), UInt8(((ticks << 1) & 0xfe) | 1)]
        let pesLength = header.count - 6 + es.count
        if bounded, pesLength <= 0xffff { header[4] = UInt8(pesLength >> 8); header[5] = UInt8(pesLength & 0xff) }
        let data = [UInt8](Data(header) + es)
        var out: [Data] = []
        var offset = 0
        while offset < data.count {
            let first = offset == 0
            let remaining = data.count - offset
            // Adaptation field content (after its length byte): PCR on the first packet, stuffing on the last.
            var adaptation: [UInt8]?
            if first, let pcr {
                let base = Int64((pcr * 90_000).rounded()) & 0x1_ffff_ffff
                adaptation = [0x10, UInt8((base >> 25) & 0xff), UInt8((base >> 17) & 0xff), UInt8((base >> 9) & 0xff),
                              UInt8((base >> 1) & 0xff), UInt8(((base & 1) << 7) | 0x7e), 0x00]
            }
            var capacity = 184 - (adaptation.map { 1 + $0.count } ?? 0)
            if remaining < capacity {
                let stuffing = capacity - remaining
                if adaptation == nil {
                    adaptation = stuffing >= 2 ? [0x00] + [UInt8](repeating: 0xff, count: stuffing - 2) : []
                } else {
                    adaptation! += [UInt8](repeating: 0xff, count: stuffing)
                }
                capacity = remaining
            }
            var p: [UInt8] = [0x47, UInt8((first ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xff),
                              (adaptation == nil ? 0x10 : 0x30) | nextCC(pid)]
            if let adaptation { p.append(UInt8(adaptation.count)); p += adaptation }
            p += data[offset..<(offset + capacity)]
            offset += capacity
            out.append(Data(p))
            packetsSincePSI += 1
        }
        return out
    }

    static func crc(_ data: [UInt8]) -> [UInt8] {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1 }
        }
        return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xff), UInt8((crc >> 8) & 0xff), UInt8(crc & 0xff)]
    }
}
