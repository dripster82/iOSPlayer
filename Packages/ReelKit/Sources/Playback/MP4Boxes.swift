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
}
