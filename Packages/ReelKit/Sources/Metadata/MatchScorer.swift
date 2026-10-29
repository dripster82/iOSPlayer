import Foundation
import MediaCore

/// Picks a result from a TMDb search and says how sure it is. See PLAN.md §11.4 step 4.
public enum MatchScorer {

    public struct Decision<T: Sendable>: Sendable {
        public var pick: T?
        public var confidence: MatchConfidence
        public var alternatives: [T]
    }

    /// `yearFiltered`: the results came from a search TMDb already narrowed to the file's year (it
    /// matches any release, regional ones included), so a lone answer is from that year even when
    /// its primary date says otherwise (A Grand Day Out: UK 1989, US 1990, re-release 1994).
    public static func decideMovie(_ results: [TMDbMovieSummary], parsed: ParsedName, yearFiltered: Bool = false) -> Decision<TMDbMovieSummary> {
        decide(results, parsed: parsed, yearFiltered: yearFiltered, title: \.title, altTitle: \.originalTitle, year: \.year, popularity: \.popularity)
    }

    public static func decideShow(_ results: [TMDbShowSummary], parsed: ParsedName, yearFiltered: Bool = false) -> Decision<TMDbShowSummary> {
        decide(results, parsed: parsed, yearFiltered: yearFiltered, title: \.name, altTitle: \.originalName, year: \.year, popularity: \.popularity)
    }

    private static func decide<T: Sendable>(_ results: [T], parsed: ParsedName, yearFiltered: Bool = false, title: KeyPath<T, String>, altTitle: KeyPath<T, String?>, year: KeyPath<T, Int?>, popularity: KeyPath<T, Double?>) -> Decision<T> {
        guard !results.isEmpty else { return Decision(pick: nil, confidence: .unmatched, alternatives: []) }
        let wanted = normalise(parsed.title)

        let scored = results.map { r -> Scored<T> in
            var s = Scored<T>(result: r, score: 0, popularity: r[keyPath: popularity] ?? 0)
            let t = normalise(r[keyPath: title]), alt = normalise(r[keyPath: altTitle] ?? "")
            // "Super Heroes" and "Superheroes" are the same title; so are "Teeage" and "Teenage" (a typo).
            let squashed = wanted.replacingOccurrences(of: " ", with: "")
            if t == wanted || alt == wanted || t.replacingOccurrences(of: " ", with: "") == squashed || alt.replacingOccurrences(of: " ", with: "") == squashed { s.score += 10; s.exactTitle = true }
            else if similarity(t, wanted) > 0.9 { s.score += 8 }
            else if t.hasPrefix(wanted) || wanted.hasPrefix(t) || contained(t, in: wanted) { s.score += 5 }
            else if similarity(t, wanted) > 0.8 { s.score += 4 }
            if let py = parsed.year, let ry = r[keyPath: year] {
                // Premieres, festival runs and regional releases put a title's year a little either
                // side of its primary date; only a gap of several years counts against it.
                let gap = abs(py - ry)
                if gap == 0 { s.score += 6; s.exactYear = true } else if gap == 1 { s.score += 3 } else if gap > 3 && !yearFiltered { s.score -= 4 }
                // TMDb's one and only answer for the year: its own fuzzy search has already done the
                // hard part ("South Park Post Covid Covid Returns" → "...: The Return of COVID").
                if results.count == 1, yearFiltered || gap <= 1 { s.score += 3 }
            }
            s.score += min(3, s.popularity / 50) // tie-breaker only
            return s
        }.sorted { $0.score > $1.score }

        let best = scored[0]
        let runnerUp = scored.count > 1 ? scored[1].score : -100
        let alternatives = scored.prefix(3).map(\.result)

        if best.score >= 12 && best.score - runnerUp >= 4 { return Decision(pick: best.result, confidence: .autoHigh, alternatives: alternatives) }
        // The exact title from the exact year, and the runner-up is either not that (same title a
        // year off, a stage show, a short) or a same-named obscurity: Aladdin (1992) has three
        // entries, and the one everyone means is far more popular than the others.
        if best.exactTitle, best.exactYear, scored.count > 1 {
            let second = scored[1]
            if !(second.exactTitle && second.exactYear) || best.popularity >= 4 * second.popularity + 1 {
                return Decision(pick: best.result, confidence: .autoHigh, alternatives: alternatives)
            }
        }
        if best.score >= 8 { return Decision(pick: best.result, confidence: .autoLow, alternatives: alternatives) }
        // Weaker evidence still beats Needs Review, as long as it is flagged "?" and fixable:
        // any title relationship (prefix or similar, e.g. "Ninjago: Masters of Spinjitzu" for "LEGO Ninjago
        // Masters of Spinjitzu"), or TMDb's single hit for a query it understood through an alternative
        // title ("Shingeki no Kyojin" → Attack on Titan). A year that clearly disagrees still blocks it.
        let yearClash = parsed.year.map { py in best.result[keyPath: year].map { abs(py - $0) > 1 } ?? false } ?? false
        if !yearClash, best.score >= 4 || results.count == 1 { return Decision(pick: best.result, confidence: .autoLow, alternatives: alternatives) }
        return Decision(pick: nil, confidence: .unmatched, alternatives: alternatives)
    }

    private struct Scored<T> { var result: T; var score: Double; var exactTitle = false; var exactYear = false; var popularity: Double }

    /// The result's title sits whole inside the file's, as words: "A Close Shave" in
    /// "Wallace and Gromit A Close Shave". Needs two or more words, so "Up" never matches everything.
    static func contained(_ t: String, in wanted: String) -> Bool {
        guard t.split(separator: " ").count >= 2 else { return false }
        return (" " + wanted + " ").contains(" " + t + " ")
    }

    public static func normalise(_ s: String) -> String {
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
