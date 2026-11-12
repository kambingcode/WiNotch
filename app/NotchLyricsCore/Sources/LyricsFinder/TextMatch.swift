import Foundation

enum TextMatch {
    private static let variantPattern = try! NSRegularExpression(
        pattern: #"\b(live|remix|acoustic|instrumental|karaoke|cover|demo|ver\.?|(?<!album )(?<!original )(?<!single )(?<!radio )version|sped up|slowed|nightcore)\b|伴奏|双声道"#,
        options: [.caseInsensitive]
    )

    /// Drops a trailing " - ..." or bracketed part, keeping the song's own name.
    static func coreTitle(_ title: String) -> String {
        var value = title
        if let dash = value.range(of: " - "), dash.lowerBound != value.startIndex {
            value = String(value[..<dash.lowerBound])
        }
        if let bracket = value.firstIndex(where: { "([（【".contains($0) }), bracket != value.startIndex {
            value = String(value[..<bracket])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Lowercase letters and digits only, so spacing and accents do not matter.
    static func folded(_ text: String) -> String {
        let value = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(value.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    static func sameTitle(_ first: String, _ second: String) -> Bool {
        let left = folded(coreTitle(first))
        return !left.isEmpty && left == folded(coreTitle(second))
    }

    /// True for live, remix and similar releases, whose lyrics or timing differ.
    static func isVariant(_ title: String) -> Bool {
        variantPattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    static func artistParts(_ artist: String) -> [String] {
        artist
            .replacingOccurrences(of: " feat. ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " ft. ", with: ",", options: .caseInsensitive)
            .split(whereSeparator: { ",&、".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func sameArtist(_ candidate: String, _ wanted: String) -> Bool {
        let found = folded(candidate)
        guard !found.isEmpty else { return false }
        return ([wanted] + artistParts(wanted)).map(folded).contains { part in
            !part.isEmpty && (found.contains(part) || part.contains(found))
        }
    }
}
