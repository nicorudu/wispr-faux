import Foundation

/// Word error rate for comparing models: (substitutions + deletions + insertions) divided
/// by the number of reference words. Compares lowercase words with punctuation stripped,
/// so "Hello, world." matches "hello world".
public enum WordErrorRate {
    public static func compute(reference: String, hypothesis: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    /// Lowercase words with punctuation stripped (inner apostrophes kept).
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { word in
                // Keep letters, digits and inner apostrophes ("don't"); drop other punctuation.
                String(word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "’" })
                    .replacingOccurrences(of: "’", with: "'")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein distance over words.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
