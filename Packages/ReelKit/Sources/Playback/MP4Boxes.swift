import Foundation

/// Just enough ISO BMFF box handling to rewrite what VLC's fragmented muxer gets wrong for Apple's
/// player: the EAC3 sample entry it writes as a QuickTime version-1 sound description (CoreMedia
/// refuses it; version 0 is accepted), and fragments whose data offsets are implicit rather than
/// moof-relative. Everything else passes through byte for byte.
enum MP4Boxes {
    indirect enum Box {
        case leaf(type: String, payload: Data)
        case container(type: String, children: [Box])
        /// `stsd` carries an 8-byte header (version/flags + entry count) before its entries.
        case stsd(header: Data, entries: [Box])

        var type: String {
            switch self { case .leaf(let t, _), .container(let t, _): t; case .stsd: "stsd" }
        }
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf", "edts", "dinf"]

    static func parse(_ data: Data) -> [Box] { parse(data, data.startIndex, data.endIndex) }

    private static func parse(_ data: Data, _ start: Int, _ end: Int) -> [Box] {
        var out: [Box] = []
        var off = start
        while off + 8 <= end {
            var size = Int(be32(data, off))
            let type = String(decoding: data[(off + 4)..<(off + 8)], as: UTF8.self)
            var header = 8
            if size == 1, off + 16 <= end { size = Int(be64(data, off + 8)); header = 16 }
            if size == 0 { size = end - off }
            guard size >= header, off + size <= end else { break }
            let body = data[(off + header)..<(off + size)]
            if containers.contains(type) { out.append(.container(type: type, children: parse(data, off + header, off + size))) }
            else if type == "stsd", body.count >= 8 { out.append(.stsd(header: Data(body.prefix(8)), entries: parse(data, off + header + 8, off + size))) }
            else { out.append(.leaf(type: type, payload: Data(body))) }
            off += size
        }
        return out
    }

    static func build(_ boxes: [Box]) -> Data {
        var out = Data()
        for b in boxes {
            switch b {
            case .leaf(let t, let p): out.append(box(t, p))
            case .container(let t, let c): out.append(box(t, build(c)))
            case .stsd(let h, let e): out.append(box("stsd", h + build(e)))
            }
        }
        return out
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        d.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Data($0) })
        d.append(contentsOf: Array(type.utf8))
        d.append(payload)
        return d
    }

    static func be32(_ d: Data, _ at: Int) -> UInt32 {
        guard at + 4 <= d.endIndex else { return 0 }
        return UInt32(bigEndian: d[at..<(at + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }
    static func be64(_ d: Data, _ at: Int) -> UInt64 {
        guard at + 8 <= d.endIndex else { return 0 }
        return UInt64(bigEndian: d[at..<(at + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
    }
    static func put32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    // MARK: - The init segment

    /// A sound track's sample entries become version 0, and HEVC entries are relabelled hvc1.
    static func fixInit(_ moov: Data) -> Data {
        let tree = parse(moov)
        return build(tree.map { fixInitBox($0) })
    }

    private static func fixInitBox(_ box: Box) -> Box {
        switch box {
        case .container(let t, let children):
            if t == "trak" {
                let isSound = children.contains { c in
                    if case .container("mdia", let m) = c { return m.contains { if case .leaf("hdlr", let p) = $0 { return p.count >= 12 && String(decoding: p[(p.startIndex + 8)..<(p.startIndex + 12)], as: UTF8.self) == "soun" } else { return false } } }
                    return false
                }
                return .container(type: t, children: children.map { fixTrakChild($0, sound: isSound) })
            }
            return .container(type: t, children: children.map { fixInitBox($0) })
        default: return box
        }
    }

    private static func fixTrakChild(_ box: Box, sound: Bool) -> Box {
        switch box {
        case .container(let t, let children): return .container(type: t, children: children.map { fixTrakChild($0, sound: sound) })
        case .stsd(let h, let entries): return .stsd(header: h, entries: entries.map { fixSampleEntry($0, sound: sound) })
        default: return box
        }
    }

    private static func fixSampleEntry(_ box: Box, sound: Bool) -> Box {
        guard case .leaf(let t, let p) = box else { return box }
        if sound, p.count >= 44, UInt16(bigEndian: p[(p.startIndex + 8)..<(p.startIndex + 10)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }) == 1 {
            // QuickTime sound description v1 → v0: version to 0, drop the 16 v1 fields after the 28-byte base.
            var out = Data(p.prefix(8)); out.append(contentsOf: [0, 0]); out.append(p[(p.startIndex + 10)..<(p.startIndex + 28)]); out.append(p[(p.startIndex + 44)...])
            return .leaf(type: t, payload: out)
        }
        if t == "hev1" { return .leaf(type: "hvc1", payload: p) }
        return box
    }

    // MARK: - Fragments

    /// Rewrites a moof so every traf uses default-base-is-moof with an explicit data offset into the
    /// mdat that follows it. `trexSizes` gives each track's default sample size from the init, for
    /// runs that carry neither their own sizes nor a tfhd default.
    static func fixMoof(_ moof: Data, trexSizes: [UInt32: UInt32]) -> Data {
        guard case .container("moof", let children)? = parse(moof).first else { return moof }
        struct Run { var tfhd: Data; var others: [Box]; var trun: Data; var bytes: Int; var hasOffset: Bool }
        var runs: [Run] = []
        var mfhd: Box?
        for c in children {
            if case .leaf("mfhd", _) = c { mfhd = c; continue }
            guard case .container("traf", let parts) = c else { continue }
            var tfhd = Data(), trun = Data(), others: [Box] = []
            for p in parts {
                switch p {
                case .leaf("tfhd", let d): tfhd = d
                case .leaf("trun", let d): trun = d
                default: others.append(p)
                }
            }
            guard !tfhd.isEmpty, !trun.isEmpty else { continue }
            // tfhd: strip a base_data_offset if present, set default-base-is-moof.
            var flags = be32(tfhd, tfhd.startIndex) & 0xFFFFFF
            let trackID = be32(tfhd, tfhd.startIndex + 4)
            var fields = Data(tfhd[(tfhd.startIndex + 8)...])
            if flags & 0x1 != 0 { fields.removeFirst(8); flags &= ~0x1 }
            flags |= 0x020000
            var sizeOff = 0
            if flags & 0x2 != 0 { sizeOff += 4 }
            if flags & 0x8 != 0 { sizeOff += 4 }
            var defaultSize = trexSizes[trackID] ?? 0
            if flags & 0x10 != 0 { defaultSize = be32(fields, fields.startIndex + sizeOff) }
            let newTfhd = put32(flags) + put32(trackID) + fields
            // trun: total sample bytes, and whether a data_offset field exists.
            let tflags = be32(trun, trun.startIndex) & 0xFFFFFF
            let count = Int(be32(trun, trun.startIndex + 4))
            var p = trun.startIndex + 8
            let hasOffset = tflags & 0x1 != 0
            if hasOffset { p += 4 }
            if tflags & 0x4 != 0 { p += 4 }
            let per = (tflags & 0x100 != 0 ? 4 : 0) + (tflags & 0x200 != 0 ? 4 : 0) + (tflags & 0x400 != 0 ? 4 : 0) + (tflags & 0x800 != 0 ? 4 : 0)
            var bytes = 0
            if tflags & 0x200 != 0 {
                let sizeAt = tflags & 0x100 != 0 ? 4 : 0
                for i in 0..<count { bytes += Int(be32(trun, p + i * per + sizeAt)) }
            } else {
                bytes = count * Int(defaultSize)
            }
            var newTrun = trun
            if !hasOffset {
                newTrun = put32(tflags | 0x1) + put32(UInt32(count)) + put32(0) + Data(trun[(trun.startIndex + 8)...])
            }
            runs.append(Run(tfhd: newTfhd, others: others, trun: newTrun, bytes: bytes, hasOffset: true))
        }
        guard !runs.isEmpty else { return moof }
        func assemble(_ offsets: [Int]) -> Data {
            var body = Data()
            if let mfhd { body.append(build([mfhd])) }
            for (run, off) in zip(runs, offsets) {
                var trun = run.trun
                trun.replaceSubrange(trun.startIndex + 8..<trun.startIndex + 12, with: put32(UInt32(truncatingIfNeeded: off)))
                var traf = box("tfhd", run.tfhd)
                traf.append(build(run.others))
                traf.append(box("trun", trun))
                body.append(box("traf", traf))
            }
            return box("moof", body)
        }
        let probe = assemble(Array(repeating: 0, count: runs.count))
        var offsets: [Int] = []
        var acc = probe.count + 8   // the mdat header follows the moof
        for run in runs { offsets.append(acc); acc += run.bytes }
        return assemble(offsets)
    }

    /// Track id → default sample size from the init's trex boxes.
    static func trexSizes(_ moov: Data) -> [UInt32: UInt32] {
        var out: [UInt32: UInt32] = [:]
        func walk(_ boxes: [Box]) {
            for b in boxes {
                switch b {
                case .container(_, let c): walk(c)
                case .leaf("trex", let p): out[be32(p, p.startIndex + 4)] = be32(p, p.startIndex + 16)
                default: break
                }
            }
        }
        walk(parse(moov))
        return out
    }

    // MARK: - Tracks

    /// One track of a moov, in moov order.
    struct Track { var id: UInt32; var isVideo: Bool; var timescale: UInt32; var language: String; var codec: String; var trexSize: UInt32 }

    /// The tracks described by `data` (a moov, or an init segment that contains one).
    static func tracks(in data: Data) -> [Track] {
        var trex: [UInt32: UInt32] = [:]
        var out: [Track] = []
        func walk(_ boxes: [Box]) {
            for b in boxes {
                switch b {
                case .container("trak", let children):
                    var id: UInt32 = 0, scale: UInt32 = 0, lang = "und", codec = "", video = false
                    for c in children {
                        if case .leaf("tkhd", let p) = c, p.count >= 24 { id = p[p.startIndex] == 1 ? be32(p, p.startIndex + 20) : be32(p, p.startIndex + 12) }
                        if case .container("mdia", let m) = c {
                            for mb in m {
                                if case .leaf("mdhd", let p) = mb, p.count >= 22 {
                                    let v1 = p[p.startIndex] == 1
                                    scale = v1 ? be32(p, p.startIndex + 20) : be32(p, p.startIndex + 12)
                                    let at = p.startIndex + (v1 ? 32 : 20)
                                    if at + 2 <= p.endIndex {
                                        let packed = UInt16(p[at]) << 8 | UInt16(p[at + 1])
                                        let chars = [(packed >> 10) & 0x1F, (packed >> 5) & 0x1F, packed & 0x1F].map { Character(UnicodeScalar(UInt8($0) + 0x60)) }
                                        let l = String(chars)
                                        if l.allSatisfy({ $0.isLetter }) { lang = l }
                                    }
                                }
                                if case .leaf("hdlr", let p) = mb, p.count >= 12 { video = String(decoding: p[(p.startIndex + 8)..<(p.startIndex + 12)], as: UTF8.self) == "vide" }
                                if case .container("minf", let minf) = mb {
                                    for s in minf { if case .container("stbl", let stbl) = s { for t in stbl { if case .stsd(_, let entries) = t, let first = entries.first { codec = codecName(of: first) } } } }
                                }
                            }
                        }
                    }
                    if id > 0 { out.append(Track(id: id, isVideo: video, timescale: scale, language: lang, codec: codec, trexSize: 0)) }
                case .leaf("trex", let p): trex[be32(p, p.startIndex + 4)] = be32(p, p.startIndex + 16)
                case .container(_, let c): walk(c)
                default: break
                }
            }
        }
        walk(parse(data))
        return out.map { var t = $0; t.trexSize = trex[t.id] ?? 0; return t }
    }

    /// The sample entry's type, except that an `mp4a` entry is named by what its esds says it
    /// carries: "mp4a" for AAC, "mp3" for MPEG audio (OTI 0x69/0x6B), which Apple's player will not
    /// take in an HLS segment.
    static func codecName(of entry: Box) -> String {
        guard case .leaf(let type, let payload) = entry else { return entry.type }
        guard type == "mp4a", payload.count > 28 else { return type }
        guard let esds = parse(payload[(payload.startIndex + 28)...]).first(where: { $0.type == "esds" }), case .leaf(_, let p) = esds else { return type }
        // ES_Descriptor (tag 3) … DecoderConfigDescriptor (tag 4): [tag][length bytes with 0x80 continuation][objectTypeIndication]
        var i = p.startIndex + 4   // version/flags
        func skipLength() { while i < p.endIndex, p[i] & 0x80 != 0 { i += 1 }; if i < p.endIndex { i += 1 } }
        guard i < p.endIndex, p[i] == 0x03 else { return type }
        i += 1; skipLength()
        i += 3   // ES_ID (2) + flags (1); dependsOn/URL/OCR fields are absent in VLC's and ffmpeg's output
        guard i < p.endIndex, p[i] == 0x04 else { return type }
        i += 1; skipLength()
        guard i < p.endIndex else { return type }
        switch p[i] {
        case 0x69, 0x6B: return "mp3"
        case 0x40, 0x66, 0x67, 0x68: return "mp4a"
        default: return "mp4a-\(String(p[i], radix: 16))"
        }
    }

    /// What Apple's player can take over AirPlay in an HLS segment, by sample entry type.
    static let airPlayVideo: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe"]
    static let airPlayAudio: Set<String> = ["mp4a", "ac-3", "ec-3", "alac", "fLaC"]

    /// A plain-language name for a codec AirPlay refuses.
    static func describe(codec: String) -> String {
        switch codec {
        case "mp4v", "xvid", "XVID", "DX50", "DIVX", "divx": "MPEG-4 Part 2 (XviD/DivX)"
        case "vp08", "vp09": "VP9"
        case "av01": "AV1"
        case "mp3": "MP3"
        case "Opus": "Opus"
        case "dtsc", "dtsh", "dtsl", "dtse": "DTS"
        case "mlpa": "TrueHD"
        case "mjpg", "jpeg": "Motion JPEG"
        default: codec
        }
    }

    /// The moov with only track `id` (and its trex), for a one-track init segment.
    static func initSegment(_ moov: Data, keeping id: UInt32) -> Data {
        func filter(_ boxes: [Box]) -> [Box] {
            boxes.compactMap { b in
                switch b {
                case .container("trak", let c):
                    let tid = c.compactMap { if case .leaf("tkhd", let p) = $0 { return p[p.startIndex] == 1 ? be32(p, p.startIndex + 20) : be32(p, p.startIndex + 12) } else { return nil } }.first
                    return tid == id ? b : nil
                case .leaf("trex", let p): return be32(p, p.startIndex + 4) == id ? b : nil
                case .container(let t, let c): return .container(type: t, children: filter(c))
                default: return b
                }
            }
        }
        return build(filter(parse(moov)))
    }

    /// One run of a fragment, split out of VLC's multi-track moof.
    struct Run { var trackID: UInt32; var moof: Data; var dataStart: Int; var bytes: Int; var samples: Int }

    /// Splits a moof into one single-track moof per traf, each with default-base-is-moof and a data
    /// offset that points just past itself, plus where that run's bytes sit in the shared mdat (the
    /// runs are laid out in traf order).
    static func splitMoof(_ moof: Data, trexSizes: [UInt32: UInt32]) -> [Run] {
        guard case .container("moof", let children)? = parse(moof).first else { return [] }
        var mfhd: Box?
        var out: [Run] = []
        var dataStart = 0
        for c in children {
            if case .leaf("mfhd", _) = c { mfhd = c; continue }
            guard case .container("traf", let parts) = c else { continue }
            var tfhd = Data(), trun = Data(), others: [Box] = []
            for p in parts {
                switch p {
                case .leaf("tfhd", let d): tfhd = d
                case .leaf("trun", let d): trun = d
                default: others.append(p)
                }
            }
            guard !tfhd.isEmpty, !trun.isEmpty else { continue }
            var flags = be32(tfhd, tfhd.startIndex) & 0xFFFFFF
            let trackID = be32(tfhd, tfhd.startIndex + 4)
            var fields = Data(tfhd[(tfhd.startIndex + 8)...])
            if flags & 0x1 != 0 { fields.removeFirst(8); flags &= ~0x1 }
            flags |= 0x020000
            var sizeOff = 0
            if flags & 0x2 != 0 { sizeOff += 4 }
            if flags & 0x8 != 0 { sizeOff += 4 }
            var defaultSize = trexSizes[trackID] ?? 0
            if flags & 0x10 != 0 { defaultSize = be32(fields, fields.startIndex + sizeOff) }
            let newTfhd = put32(flags) + put32(trackID) + fields
            let tflags = be32(trun, trun.startIndex) & 0xFFFFFF
            let count = Int(be32(trun, trun.startIndex + 4))
            var p = trun.startIndex + 8
            if tflags & 0x1 != 0 { p += 4 }
            if tflags & 0x4 != 0 { p += 4 }
            let per = (tflags & 0x100 != 0 ? 4 : 0) + (tflags & 0x200 != 0 ? 4 : 0) + (tflags & 0x400 != 0 ? 4 : 0) + (tflags & 0x800 != 0 ? 4 : 0)
            var bytes = 0
            if tflags & 0x200 != 0 {
                let sizeAt = tflags & 0x100 != 0 ? 4 : 0
                for i in 0..<count { bytes += Int(be32(trun, p + i * per + sizeAt)) }
            } else {
                bytes = count * Int(defaultSize)
            }
            let rest = tflags & 0x1 != 0 ? Data(trun[(trun.startIndex + 12)...]) : Data(trun[(trun.startIndex + 8)...])
            func assemble(_ offset: Int) -> Data {
                var body = Data()
                if let mfhd { body.append(build([mfhd])) }
                var traf = box("tfhd", newTfhd)
                traf.append(build(others))
                traf.append(box("trun", put32(tflags | 0x1) + put32(UInt32(count)) + put32(UInt32(truncatingIfNeeded: offset)) + rest))
                body.append(box("traf", traf))
                return box("moof", body)
            }
            let probe = assemble(0)
            out.append(Run(trackID: trackID, moof: assemble(probe.count + 8), dataStart: dataStart, bytes: bytes, samples: count))
            dataStart += bytes
        }
        return out
    }

    /// Calls `body` with each top-level box's type and payload in `data`.
    static func forEachBox(in data: Data, _ body: (String, Data) -> Void) {
        var off = data.startIndex
        while off + 8 <= data.endIndex {
            var size = Int(be32(data, off))
            let type = String(decoding: data[(off + 4)..<(off + 8)], as: UTF8.self)
            var header = 8
            if size == 1, off + 16 <= data.endIndex { size = Int(be64(data, off + 8)); header = 16 }
            if size == 0 { size = data.endIndex - off }
            guard size >= header, off + size <= data.endIndex else { return }
            body(type, data[(off + header)..<(off + size)])
            off += size
        }
    }
}
