import Foundation
import MediaCore

/// Picks a result from a TMDb search and says how sure it is. See PLAN.md §11.4 step 4.
public enum MatchScorer {

    public struct Decision<T: Sendable>: Sendable {
        public var pick: T?
        public var confidence: MatchConfidence
        public var alternatives: [T]
    }

    public static func decideMovie(_ results: [TMDbMovieSummary], parsed: ParsedName) -> Decision<TMDbMovieSummary> {
        decide(results, parsed: parsed, title: \.title, altTitle: \.originalTitle, year: \.year, popularity: \.popularity)
    }

    public static func decideShow(_ results: [TMDbShowSummary], parsed: ParsedName) -> Decision<TMDbShowSummary> {
        decide(results, parsed: parsed, title: \.name, altTitle: \.originalName, year: \.year, popularity: \.popularity)
    }

    private static func decide<T: Sendable>(_ results: [T], parsed: ParsedName, title: KeyPath<T, String>, altTitle: KeyPath<T, String?>, year: KeyPath<T, Int?>, popularity: KeyPath<T, Double?>) -> Decision<T> {
        guard !results.isEmpty else { return Decision(pick: nil, confidence: .unmatched, alternatives: []) }
        let wanted = normalise(parsed.title)

        let scored = results.map { r -> (T, Double) in
            var score = 0.0
            let t = normalise(r[keyPath: title]), alt = normalise(r[keyPath: altTitle] ?? "")
            if t == wanted || alt == wanted { score += 10 }
            else if t.hasPrefix(wanted) || wanted.hasPrefix(t) { score += 5 }
            else if similarity(t, wanted) > 0.8 { score += 4 }
            if let py = parsed.year, let ry = r[keyPath: year] {
                if py == ry { score += 6 } else if abs(py - ry) == 1 { score += 3 } else { score -= 4 }
            }
            score += min(3, (r[keyPath: popularity] ?? 0) / 50) // tie-breaker only
            return (r, score)
        }.sorted { $0.1 > $1.1 }

        let best = scored[0]
        let runnerUp = scored.count > 1 ? scored[1].1 : -100
        let alternatives = scored.prefix(3).map(\.0)

        if best.1 >= 12 && best.1 - runnerUp >= 4 { return Decision(pick: best.0, confidence: .autoHigh, alternatives: alternatives) }
        if best.1 >= 8 { return Decision(pick: best.0, confidence: .autoLow, alternatives: alternatives) }
        return Decision(pick: nil, confidence: .unmatched, alternatives: alternatives)
    }

    static func normalise(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let stripped = folded.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
        let words = stripped.split(separator: " ").filter { !["the", "a", "an"].contains($0) }
        return words.joined(separator: " ")
    }

    /// Dice coefficient on character bigrams. Cheap and good enough for titles.
    static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> [Substring: Int] {
            var out: [Substring: Int] = [:]
            let chars = Array(s)
            guard chars.count > 1 else { return out }
            for i in 0..<(chars.count - 1) { out[Substring(String(chars[i...i+1])), default: 0] += 1 }
            return out
        }
        let ba = bigrams(a), bb = bigrams(b)
        let total = ba.values.reduce(0, +) + bb.values.reduce(0, +)
        guard total > 0 else { return a == b ? 1 : 0 }
        var overlap = 0
        for (k, v) in ba { overlap += min(v, bb[k] ?? 0) }
        return 2.0 * Double(overlap) / Double(total)
    }
}
