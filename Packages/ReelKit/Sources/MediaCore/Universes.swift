import Foundation

/// "Universes": the big groupings people browse by that TMDb collections are too narrow for.
/// TMDb's collections are per series (the Raimi Spider-Man films, the Holland ones and the
/// Spider-Verse are three collections); a universe is the studio or franchise above them.
///
/// Membership comes from TMDb's production companies and keywords on each film, filtered through
/// these lists, because raw companies ("Warner Bros. Pictures", 300 films) and keywords ("sequel")
/// make groups nobody wants.
public enum Universes {
    public struct Universe: Hashable, Identifiable, Sendable {
        public var name: String
        public var id: String { name }
    }

    /// Franchise keywords as TMDb spells them (lower-case), mapped to a display name.
    static let franchiseKeywords: [String: String] = [
        "marvel cinematic universe": "Marvel Cinematic Universe", "mcu": "Marvel Cinematic Universe",
        "marvel comic": "Marvel", "marvel comics": "Marvel", "based on marvel comics": "Marvel",
        "dc extended universe": "DC Universe", "dc universe": "DC Universe", "dceu": "DC Universe",
        "dc comics": "DC", "based on dc comics": "DC",
        "star wars": "Star Wars", "star trek": "Star Trek", "james bond": "James Bond", "007": "James Bond",
        "harry potter": "Wizarding World", "wizarding world": "Wizarding World",
        "middle-earth": "Middle-earth", "middle earth": "Middle-earth", "tolkien": "Middle-earth",
        "x-men": "X-Men", "monsterverse": "MonsterVerse", "godzilla": "MonsterVerse",
        "the conjuring universe": "The Conjuring Universe", "conjuring universe": "The Conjuring Universe",
        "jurassic park": "Jurassic Park", "jurassic world": "Jurassic Park",
        "mission impossible": "Mission: Impossible", "fast and furious": "Fast & Furious", "fast & furious": "Fast & Furious",
        "transformers": "Transformers", "alien": "Alien", "predator": "Predator", "terminator": "Terminator",
        "rocky": "Rocky", "indiana jones": "Indiana Jones", "pirates of the caribbean": "Pirates of the Caribbean",
        "the hunger games": "The Hunger Games", "twilight": "Twilight", "despicable me": "Despicable Me",
        "shrek": "Shrek", "toy story": "Toy Story", "planet of the apes": "Planet of the Apes",
        "john wick": "John Wick", "the matrix": "The Matrix", "halloween": "Halloween", "saw": "Saw",
        "ghostbusters": "Ghostbusters", "kaiju": "Kaiju", "tokusatsu": "Tokusatsu",
    ]

    /// Studios whose output people think of as a body of work, mapped to a display name.
    static let studioNames: [String: String] = [
        "marvel studios": "Marvel Cinematic Universe", "marvel entertainment": "Marvel", "marvel enterprises": "Marvel",
        "dc films": "DC Universe", "dc studios": "DC Universe", "dc entertainment": "DC", "dc comics": "DC",
        "pixar": "Pixar", "pixar animation studios": "Pixar",
        "walt disney animation studios": "Disney Animation", "walt disney feature animation": "Disney Animation",
        "studio ghibli": "Studio Ghibli", "dreamworks animation": "DreamWorks Animation", "dreamworks": "DreamWorks",
        "illumination": "Illumination", "illumination entertainment": "Illumination",
        "aardman": "Aardman", "aardman animations": "Aardman", "laika": "Laika", "laika entertainment": "Laika",
        "blue sky studios": "Blue Sky", "lucasfilm": "Star Wars", "lucasfilm ltd.": "Star Wars",
        "eon productions": "James Bond", "hammer film productions": "Hammer Horror", "hammer films": "Hammer Horror",
        "a24": "A24", "blumhouse productions": "Blumhouse", "blumhouse": "Blumhouse",
        "toho": "Toho", "toei animation": "Toei Animation", "kyoto animation": "Kyoto Animation",
        "madhouse": "Madhouse", "bones": "Bones", "mappa": "MAPPA", "ufotable": "ufotable",
        "wit studio": "WIT Studio", "production i.g": "Production I.G", "trigger": "Trigger", "gainax": "Gainax",
        "sunrise": "Sunrise", "monty python": "Monty Python", "ealing studios": "Ealing Studios",
        "studiocanal": "StudioCanal", "working title films": "Working Title", "merchant ivory productions": "Merchant Ivory",
    ]

    /// The universes one film belongs to, from its TMDb production companies and keywords.
    public static func universes(studios: [String], keywords: [String]) -> [String] {
        var out: [String] = []
        for s in studios { if let n = studioNames[s.lowercased().trimmingCharacters(in: .whitespaces)], !out.contains(n) { out.append(n) } }
        for k in keywords { if let n = franchiseKeywords[k.lowercased().trimmingCharacters(in: .whitespaces)], !out.contains(n) { out.append(n) } }
        // Marvel Cinematic Universe films are Marvel films too; keep the specific one first.
        if out.contains("Marvel Cinematic Universe"), !out.contains("Marvel") { out.append("Marvel") }
        if out.contains("DC Universe"), !out.contains("DC") { out.append("DC") }
        return out
    }
}
