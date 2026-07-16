import Foundation

struct PaddedTensor<Element: Equatable & Sendable>: Equatable, Sendable {
    let values: [Element]
    let rows: Int
    let columns: Int
}

enum SupertonicTensor {
    private static let abbreviations = [
        "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.",
        "St.", "Ave.", "Rd.", "Blvd.", "Dept.", "Inc.", "Ltd.",
        "Co.", "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
    ]

    static func pad<Element: Equatable & Sendable>(
        _ rows: [[Element]],
        with padding: Element
    ) -> PaddedTensor<Element> {
        let columns = rows.map(\.count).max() ?? 0
        return PaddedTensor(
            values: rows.flatMap { $0 + Array(repeating: padding, count: columns - $0.count) },
            rows: rows.count,
            columns: columns
        )
    }

    static func lengthMask(_ lengths: [Int], maxLength: Int? = nil) -> [Float] {
        let width = maxLength ?? lengths.max() ?? 0
        return lengths.flatMap { length in
            (0..<width).map { $0 < length ? 1 : 0 }
        }
    }

    static func concatenate(_ chunks: [[Float]], silenceSamples: Int) -> [Float] {
        guard let first = chunks.first else { return [] }
        let silence = [Float](repeating: 0, count: max(0, silenceSamples))
        return chunks.dropFirst().reduce(into: first) { result, chunk in
            result.append(contentsOf: silence)
            result.append(contentsOf: chunk)
        }
    }

    static func floatSamples(from data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.stride) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func splitText(_ text: String, maxLength: Int) -> [String] {
        precondition(maxLength > 0)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [""] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences(in: trimmed) {
            for fragment in fragments(of: sentence, maxLength: maxLength) {
                let joined = current.isEmpty ? fragment : "\(current) \(fragment)"
                if joined.count <= maxLength {
                    current = joined
                } else {
                    if !current.isEmpty { chunks.append(current) }
                    current = fragment
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }

    private static func sentences(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "([.!?])(?:\\s+|$)")
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return [text] }

        var result: [String] = []
        var start = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[start..<range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if abbreviations.contains(where: candidate.hasSuffix) { continue }
            result.append(candidate)
            start = range.upperBound
        }
        if start < text.endIndex {
            result.append(String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.filter { !$0.isEmpty }
    }

    private static func fragments(of sentence: String, maxLength: Int) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        var result: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: \Character.isWhitespace).map(String.init) {
            if word.count > maxLength {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                var remainder = word[...]
                while remainder.count > maxLength {
                    let end = remainder.index(remainder.startIndex, offsetBy: maxLength)
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                current = String(remainder)
                continue
            }
            let joined = current.isEmpty ? word : "\(current) \(word)"
            if joined.count > maxLength {
                result.append(current)
                current = word
            } else {
                current = joined
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
