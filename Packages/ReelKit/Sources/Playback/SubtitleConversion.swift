import Foundation

/// SRT (or VTT) text to WebVTT for an HLS subtitle rendition, with every cue shifted by `offset`
/// seconds (the stream's own clock starts at zero when it began part-way through the file).
public enum SubtitleConversion {
    public static func webVTT(from data: Data, shiftingBy offset: TimeInterval = 0) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var out = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000", ""]
        var cue: [String] = []
        var kept = false
        func flush() {
            if kept, cue.count > 1 { out.append(contentsOf: cue); out.append("") }
            cue = []; kept = false
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "WEBVTT" || line.hasPrefix("X-TIMESTAMP-MAP") || line.hasPrefix("NOTE") { continue }
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let a = seconds(parts[0]), let b = seconds(parts[1].components(separatedBy: " ").first ?? "") else { continue }
                let start = a - offset, end = b - offset
                guard end > 0 else { cue = []; kept = false; continue }
                cue = ["\(stamp(max(0, start))) --> \(stamp(end))"]
                kept = true
                continue
            }
            if cue.isEmpty, Int(line) != nil { continue }   // SRT cue number
            if kept { cue.append(line) }
        }
        flush()
        return out.joined(separator: "\n") + "\n"
    }

    static func seconds(_ s: String) -> TimeInterval? {
        let t = s.replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        guard parts.count >= 2, let sec = Double(parts.last!) else { return nil }
        var total = sec
        if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]) { total += h * 3600 + m * 60 }
        else if let m = Double(parts[0]) { total += m * 60 }
        return total
    }
    static func stamp(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
