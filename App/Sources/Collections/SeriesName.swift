// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Titles as series: what's left of a game's name without its place in the series, and keys
/// to compare names by.
enum SeriesName {
    /// The title without its number, volume, episode, edition or subtitle:
    /// "NEKOPARA Vol. 1" and "NEKOPARA Extra" → "NEKOPARA", "Sakura Succubus 9" →
    /// "Sakura Succubus", "KARAKARA2" → "KARAKARA", "WORLD END ECONOMiCA episode.01" →
    /// "WORLD END ECONOMiCA", "Ne no Kami - The Two Princess Knights of Kyoto Part 2" →
    /// "Ne no Kami".
    static func base(of name: String) -> String {
        var text = name.replacing(#/[™®©]/#, with: "").trimmingCharacters(in: .whitespaces)
        // A subtitle: " - …", " ~…", " -…-", ": …".
        if let cut = text.firstMatch(of: #/\s+[-–—~]|:\s/#), cut.range.lowerBound > text.startIndex {
            let head = String(text[..<cut.range.lowerBound])
            if head.count >= 2 { text = head }
        }
        while true {
            let before = text
            for pattern in trailing {
                text = text.replacing(pattern, with: "")
            }
            // A number run into the name: "KARAKARA2".
            let digits = text.reversed().prefix { $0.isASCII && $0.isNumber }.count
            if digits > 0, text.count - digits >= 3, text.dropLast(digits).last?.isLetter == true {
                text = String(text.dropLast(digits))
            }
            text = text.trimmingCharacters(in: trim)
            if text == before { break }
        }
        return text.isEmpty ? name : text
    }

    /// Trailing parts of a title that place it in a series, stripped one at a time.
    nonisolated(unsafe) private static let trailing: [Regex<Substring>] = [
        #/(?i)[\s.,:-]*\b(?:vol(?:ume)?|episode|ep|part|chapter|season|book)\.?\s*(?:[0-9]+|[ivx]+)$/#,
        #/(?i)\s+(?:[0-9]+|ii|iii|iv|v|vi|vii|viii|ix|x)$/#,
        #/(?i)\s+(?:extra|plus!?|full\s+hd\s+edition|hd\s+edition|hd|remastered|complete\s+edition|enhanced\s+edition|edition)$/#,
    ]

    private static let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—~:.,!"))

    /// A name folded for comparing: lower case, no accents or full-width forms, words of
    /// letters and digits separated by single spaces ("Muv-Luv" → "muv luv").
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// The longest run of whole words the names all start with, as the first name has it
    /// ("Doki Doki Literature Club" and "Doki Doki Literature Club Plus!" → "Doki Doki
    /// Literature Club"), or nil when they share none.
    static func commonPrefix(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        let lowered = names.map { Array($0.lowercased()) }
        let firstChars = Array(first)
        guard lowered[0].count == firstChars.count else { return names.count == 1 ? first : nil }
        var length = lowered.map(\.count).min() ?? 0
        for other in lowered.dropFirst() {
            var shared = 0
            while shared < length, other[shared] == lowered[0][shared] { shared += 1 }
            length = shared
        }
        // Back off to a word boundary in every name.
        func isBoundary(_ chars: [Character], _ index: Int) -> Bool {
            index == chars.count || !(chars[index].isLetter || chars[index].isNumber)
        }
        while length > 0, !lowered.allSatisfy({ isBoundary($0, length) }) { length -= 1 }
        let prefix = String(firstChars[..<length]).trimmingCharacters(in: trim)
        return key(prefix).isEmpty ? nil : prefix
    }
}
