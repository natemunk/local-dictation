import Foundation

/// Applies profile-owned formatting limits before the alignment validator.
/// The underlying model still sees only cleanup rules and transcript text.
struct ProfileFormattingRefiner: TextRefiner, Sendable {
    let base: any TextRefiner
    let allowInferredBullets: Bool
    let preserveParagraphBreakCount: Bool

    func refine(_ input: TextRefinementInput) async throws -> String {
        var output = try await base.refine(input)
        if !allowInferredBullets {
            output = Self.removingInferredBullets(
                from: output,
                allowedCount: Self.bulletCount(in: input.transcript)
            )
        }
        if preserveParagraphBreakCount {
            output = Self.collapsingExcessParagraphBreaks(
                in: output,
                allowedCount: Self.paragraphBreakCount(in: input.transcript)
            )
        }
        return output
    }

    private static let bulletPrefix = try! NSRegularExpression(
        pattern: #"^\s*[-*•]\s+"#
    )
    private static let paragraphBreak = try! NSRegularExpression(
        pattern: #"\n[\t ]*\n"#
    )

    private static func bulletCount(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
            let line = String($1)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return $0 + (bulletPrefix.firstMatch(in: line, range: range) == nil ? 0 : 1)
        }
    }

    private static func removingInferredBullets(
        from text: String,
        allowedCount: Int
    ) -> String {
        var remaining = allowedCount
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { substring in
                let line = String(substring)
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard bulletPrefix.firstMatch(in: line, range: range) != nil else {
                    return line
                }
                if remaining > 0 {
                    remaining -= 1
                    return line
                }
                return bulletPrefix.stringByReplacingMatches(
                    in: line,
                    range: range,
                    withTemplate: ""
                )
            }
            .joined(separator: "\n")
    }

    private static func paragraphBreakCount(in text: String) -> Int {
        paragraphBreak.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    private static func collapsingExcessParagraphBreaks(
        in text: String,
        allowedCount: Int
    ) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = paragraphBreak.matches(in: text, range: fullRange)
        guard matches.count > allowedCount else { return text }

        var output = text
        for match in matches.dropFirst(allowedCount).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: "\n")
        }
        return output
    }
}
