//
//  TextNormalizer.swift
//  ResearchBase
//
//  Phase 1, Step 1B
//
//  Small text helpers used for matching (creators.norm), citation keys,
//  and identifiers. Pure functions, no database.
//

import Foundation

nonisolated enum TextNormalizer {

    /// Lower-case, accents removed, extra spaces collapsed. Used for matching and search.
    /// "Müller  Étienne" -> "muller etienne"
    static func norm(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Only a-z and 0-9, lower-case, accents removed. "van der Berg" -> "vanderberg"
    static func asciiLettersAndDigits(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return String(folded.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// DOI as the schema wants it: lower-case, no URL prefix. Empty becomes nil.
    static func doi(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }

        let prefixes = [
            "https://doi.org/", "http://doi.org/",
            "https://dx.doi.org/", "http://dx.doi.org/",
            "doi.org/", "doi:"
        ]
        for prefix in prefixes where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// arXiv id without URL or "arXiv:" prefix. Empty becomes nil.
    static func arxivID(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        let lower = value.lowercased()
        let prefixes = ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "arxiv.org/abs/", "arxiv:"]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
