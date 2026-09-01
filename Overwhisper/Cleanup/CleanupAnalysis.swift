import Foundation

enum CleanupVocabularyError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptySpokenForm(index: Int)
    case invalidProtectedPattern(name: String, expression: String)

    var description: String {
        switch self {
        case let .emptySpokenForm(index):
            "Vocabulary replacement at index \(index) has an empty spoken form."
        case let .invalidProtectedPattern(name, expression):
            "Protected pattern '\(name)' is not a valid regular expression: \(expression)"
        }
    }
}

struct CleanupLexicalToken: Equatable, Sendable {
    let text: String
    let canonical: String
    let range: CleanupTextRange
}

enum CleanupText {
    private static let lexicalExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#
    )

    static func byteRange(in text: String, for range: Range<String.Index>) -> CleanupTextRange {
        let lower = text.utf8.distance(
            from: text.utf8.startIndex,
            to: range.lowerBound.samePosition(in: text.utf8)!
        )
        let upper = text.utf8.distance(
            from: text.utf8.startIndex,
            to: range.upperBound.samePosition(in: text.utf8)!
        )
        return CleanupTextRange(lower, upper)
    }

    static func stringIndex(in text: String, atUTF8Offset offset: Int) -> String.Index? {
        guard offset >= 0, offset <= text.utf8.count else { return nil }
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        return String.Index(utf8Index, within: text)
    }

    static func stringRange(in text: String, for range: CleanupTextRange) -> Range<String.Index>? {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= text.utf8.count
        else { return nil }

        guard let lower = stringIndex(in: text, atUTF8Offset: range.lowerBound),
              let upper = stringIndex(in: text, atUTF8Offset: range.upperBound)
        else { return nil }
        return lower..<upper
    }

    static func substring(in text: String, range: CleanupTextRange) -> String? {
        guard let stringRange = stringRange(in: text, for: range) else { return nil }
        return String(text[stringRange])
    }

    static func lexicalTokens(in text: String) -> [CleanupLexicalToken] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return lexicalExpression.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range])
            let canonical = token
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "’", with: "")
                .lowercased()
            return CleanupLexicalToken(
                text: token,
                canonical: canonical,
                range: byteRange(in: text, for: range)
            )
        }
    }
}

struct CleanupCommandProcessor: Sendable {
    private static let sentenceBoundaryCharacters = CharacterSet(charactersIn: ".!?")
    private static let closingBoundaryCharacters = CharacterSet(charactersIn: "\"'”’)]}")

    private static let recognizedExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])(?:make[ \t]+that[ \t]+a[ \t]+bullet[ \t]+list|new[ \t]+paragraph|scratch[ \t]+that|new[ \t]+line|bullet[ \t]+list)(?![\p{L}\p{N}_])"#,
        options: [.caseInsensitive]
    )

    /// Deliberately narrow. These phrases are surfaced as metadata but are
    /// never guessed at or executed.
    private static let unsupportedExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])(?:make[ \t]+that[ \t]+a[ \t]+numbered[ \t]+list|make[ \t]+that[ \t]+(?:bold|italic)|numbered[ \t]+list|new[ \t]+sentence|next[ \t]+(?:line|paragraph)|delete[ \t]+that|scratch[ \t]+this|undo[ \t]+that|redo[ \t]+that|bold[ \t]+that|italicize[ \t]+that|all[ \t]+caps)(?![\p{L}\p{N}_])"#,
        options: [.caseInsensitive]
    )

    func analyze(_ text: String) -> CleanupCommandResult {
        analyze(FinalTranscript(text: text))
    }

    func analyze(_ transcript: FinalTranscript) -> CleanupCommandResult {
        let analysis = commandAnalysis(
            in: transcript.text,
            boundaries: transcript.boundaries
        )
        return CleanupCommandResult(
            text: transcript.text,
            recognizedCommands: analysis.recognized.map(\.occurrence),
            unrecognizedCommandCandidates: analysis.unrecognized
        )
    }

    func process(_ text: String) -> CleanupCommandResult {
        process(FinalTranscript(text: text))
    }

    func process(_ transcript: FinalTranscript) -> CleanupCommandResult {
        let text = transcript.text
        let analysis = commandAnalysis(in: text, boundaries: transcript.boundaries)
        let matches = analysis.recognized
        var output = ""
        var outputBoundaryOffsets: [Int] = []
        var cursor = text.startIndex
        var bulletMode = false

        for match in matches {
            appendSourceText(
                text[cursor..<match.stringRange.lowerBound],
                sourceRange: cursor..<match.stringRange.lowerBound,
                sourceText: text,
                sourceBoundaries: transcript.boundaries,
                to: &output,
                mappedBoundaryOffsets: &outputBoundaryOffsets
            )
            trimTrailingHorizontalWhitespace(in: &output)
            pruneBoundaryOffsets(&outputBoundaryOffsets, in: output)

            switch match.occurrence.kind {
            case .scratchThat:
                scratchLastSegment(
                    in: &output,
                    asrBoundaryOffsets: outputBoundaryOffsets
                )
                if !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix("- ") {
                    output.append(" ")
                }
            case .newLine:
                trimTrailingHorizontalWhitespace(in: &output)
                output.append(bulletMode ? "\n- " : "\n")
            case .newParagraph:
                trimTrailingHorizontalWhitespace(in: &output)
                trimDanglingBullet(in: &output)
                appendParagraphBreak(to: &output)
                bulletMode = false
            case .bulletList:
                beginBulletList(in: &output)
                bulletMode = true
            case .makeThatABulletList:
                makeLastParagraphABulletList(in: &output)
                outputBoundaryOffsets.removeAll()
                appendParagraphBreak(to: &output)
                bulletMode = false
            }
            pruneBoundaryOffsets(&outputBoundaryOffsets, in: output)

            cursor = cursorAfterCommand(match.stringRange.upperBound, in: text)
        }

        appendSourceText(
            text[cursor...],
            sourceRange: cursor..<text.endIndex,
            sourceText: text,
            sourceBoundaries: transcript.boundaries,
            to: &output,
            mappedBoundaryOffsets: &outputBoundaryOffsets
        )
        trimTrailingHorizontalWhitespace(in: &output)
        trimDanglingBullet(in: &output)
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)

        return CleanupCommandResult(
            text: output,
            recognizedCommands: matches.map(\.occurrence),
            unrecognizedCommandCandidates: analysis.unrecognized
        )
    }

    private func appendSourceText(
        _ source: Substring,
        sourceRange: Range<String.Index>,
        sourceText: String,
        sourceBoundaries: [TranscriptBoundary],
        to output: inout String,
        mappedBoundaryOffsets: inout [Int]
    ) {
        let outputOffset = output.utf8.count
        let sourceLowerOffset = sourceText[..<sourceRange.lowerBound].utf8.count
        let sourceUpperOffset = sourceText[..<sourceRange.upperBound].utf8.count
        output.append(contentsOf: source)

        for boundary in sourceBoundaries
        where boundary.utf8Offset >= sourceLowerOffset
            && boundary.utf8Offset < sourceUpperOffset
        {
            mappedBoundaryOffsets.append(
                outputOffset + boundary.utf8Offset - sourceLowerOffset
            )
        }
    }

    private func pruneBoundaryOffsets(_ offsets: inout [Int], in text: String) {
        var seen = Set<Int>()
        offsets = offsets
            .filter { offset in
                offset > 0
                    && offset < text.utf8.count
                    && CleanupText.stringIndex(in: text, atUTF8Offset: offset) != nil
                    && seen.insert(offset).inserted
            }
            .sorted()
    }

    private struct RecognizedMatch {
        let occurrence: CleanupCommandOccurrence
        let stringRange: Range<String.Index>
    }

    private struct CommandAnalysis {
        let recognized: [RecognizedMatch]
        let unrecognized: [CleanupUnrecognizedCommandCandidate]
    }

    private func commandAnalysis(
        in text: String,
        boundaries: [TranscriptBoundary]
    ) -> CommandAnalysis {
        let allMatches = allRecognizedMatches(in: text)
        let recognized = allMatches.filter { match in
            isStandalone(
                match,
                in: text,
                boundaries: boundaries,
                allMatches: allMatches
            )
        }
        let recognizedRanges = Set(recognized.map { $0.occurrence.sourceRange })
        let invalidRecognized = allMatches
            .filter { !recognizedRanges.contains($0.occurrence.sourceRange) }
            .map { match in
                CleanupUnrecognizedCommandCandidate(
                    phrase: match.occurrence.phrase,
                    sourceRange: match.occurrence.sourceRange
                )
            }
        let allUnrecognized = invalidRecognized + unsupportedMatches(in: text)
        return CommandAnalysis(
            recognized: recognized,
            unrecognized: allUnrecognized.sorted {
                if $0.sourceRange.lowerBound != $1.sourceRange.lowerBound {
                    return $0.sourceRange.lowerBound < $1.sourceRange.lowerBound
                }
                return $0.sourceRange.upperBound < $1.sourceRange.upperBound
            }
        )
    }

    private func allRecognizedMatches(in text: String) -> [RecognizedMatch] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.recognizedExpression.matches(in: text, range: fullRange).compactMap { match in
            guard let stringRange = Range(match.range, in: text) else { return nil }
            let phrase = String(text[stringRange])
            guard let kind = commandKind(for: phrase) else { return nil }
            return RecognizedMatch(
                occurrence: CleanupCommandOccurrence(
                    kind: kind,
                    phrase: phrase,
                    sourceRange: CleanupText.byteRange(in: text, for: stringRange)
                ),
                stringRange: stringRange
            )
        }
    }

    private func isStandalone(
        _ match: RecognizedMatch,
        in text: String,
        boundaries: [TranscriptBoundary],
        allMatches: [RecognizedMatch]
    ) -> Bool {
        guard hasBoundary(
            before: match.stringRange.lowerBound,
            in: text,
            boundaries: boundaries
        ), hasBoundary(
            after: match.stringRange.upperBound,
            in: text,
            boundaries: boundaries
        ) else {
            return false
        }

        guard match.occurrence.kind == .scratchThat else { return true }
        return hasPriorBoundedPhrase(
            before: match.stringRange.lowerBound,
            in: text,
            excluding: allMatches
        )
    }

    private func hasBoundary(
        before index: String.Index,
        in text: String,
        boundaries: [TranscriptBoundary]
    ) -> Bool {
        let prefix = text[..<index]
        if prefix.allSatisfy(\.isWhitespace) {
            return true
        }

        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character.isWhitespace || Self.closingBoundaryCharacters.contains(character.unicodeScalars.first!) {
                cursor = previous
                continue
            }
            if Self.sentenceBoundaryCharacters.contains(character.unicodeScalars.first!) {
                return true
            }
            break
        }

        let targetOffset = text[..<index].utf8.count
        return boundaries.contains { boundary in
            guard isTrustworthy(boundary.source), boundary.utf8Offset <= targetOffset else {
                return false
            }
            let gap = CleanupTextRange(boundary.utf8Offset, targetOffset)
            return CleanupText.substring(in: text, range: gap)?.allSatisfy(\.isWhitespace) == true
        }
    }

    private func hasBoundary(
        after index: String.Index,
        in text: String,
        boundaries: [TranscriptBoundary]
    ) -> Bool {
        let suffix = text[index...]
        if suffix.allSatisfy(\.isWhitespace) {
            return true
        }

        var cursor = index
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || Self.closingBoundaryCharacters.contains(character.unicodeScalars.first!) {
                cursor = text.index(after: cursor)
                continue
            }
            if Self.sentenceBoundaryCharacters.contains(character.unicodeScalars.first!) {
                return true
            }
            break
        }

        let targetOffset = text[..<index].utf8.count
        return boundaries.contains { boundary in
            guard isTrustworthy(boundary.source), boundary.utf8Offset >= targetOffset else {
                return false
            }
            let gap = CleanupTextRange(targetOffset, boundary.utf8Offset)
            return CleanupText.substring(in: text, range: gap)?.allSatisfy(\.isWhitespace) == true
        }
    }

    private func isTrustworthy(_ source: TranscriptBoundarySource) -> Bool {
        switch source {
        case .pause, .segment:
            true
        }
    }

    private func hasPriorBoundedPhrase(
        before index: String.Index,
        in text: String,
        excluding commandMatches: [RecognizedMatch]
    ) -> Bool {
        let priorMatches = commandMatches.filter { $0.stringRange.upperBound <= index }
        var cursor = text.startIndex
        var priorText = ""
        for match in priorMatches {
            priorText.append(contentsOf: text[cursor..<match.stringRange.lowerBound])
            cursor = match.stringRange.upperBound
        }
        priorText.append(contentsOf: text[cursor..<index])
        return !CleanupText.lexicalTokens(in: priorText).isEmpty
    }

    private func unsupportedMatches(in text: String) -> [CleanupUnrecognizedCommandCandidate] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.unsupportedExpression.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return CleanupUnrecognizedCommandCandidate(
                phrase: String(text[range]),
                sourceRange: CleanupText.byteRange(in: text, for: range)
            )
        }
    }

    private func commandKind(for phrase: String) -> CleanupCommandKind? {
        let normalized = phrase
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        switch normalized {
        case "scratch that": return .scratchThat
        case "new line": return .newLine
        case "new paragraph": return .newParagraph
        case "make that a bullet list": return .makeThatABulletList
        case "bullet list": return .bulletList
        default: return nil
        }
    }

    private func cursorAfterCommand(_ start: String.Index, in text: String) -> String.Index {
        var cursor = start
        while cursor < text.endIndex, ",;:.!?".contains(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private func trimTrailingHorizontalWhitespace(in text: inout String) {
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }
    }

    private func trimDanglingBullet(in text: inout String) {
        while true {
            trimTrailingHorizontalWhitespace(in: &text)
            if text == "-" {
                text = ""
                continue
            }
            if text.hasSuffix("\n-") {
                text.removeLast(2)
                continue
            }
            break
        }
    }

    private func appendParagraphBreak(to text: inout String) {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { text.append("\n\n") }
    }

    private func beginBulletList(in text: inout String) {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { text.append("\n") }
        text.append("- ")
    }

    private func scratchLastSegment(
        in text: inout String,
        asrBoundaryOffsets: [Int]
    ) {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let lineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        var contentStart = lineStart
        let line = text[lineStart...]
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            contentStart = text.index(lineStart, offsetBy: 2)
        } else if line.hasPrefix("• ") {
            contentStart = text.index(lineStart, offsetBy: 2)
        }

        var searchEnd = text.endIndex
        if searchEnd > contentStart {
            let previous = text.index(before: searchEnd)
            if ".!?;:".contains(text[previous]) {
                searchEnd = previous
            }
        }

        var boundary: String.Index?
        var index = contentStart
        while index < searchEnd {
            if ".!?;:".contains(text[index]) { boundary = index }
            index = text.index(after: index)
        }

        var removalStart = contentStart
        if let boundary {
            removalStart = text.index(after: boundary)
        }
        for offset in asrBoundaryOffsets {
            guard let asrBoundary = CleanupText.stringIndex(
                in: text,
                atUTF8Offset: offset
            ),
            asrBoundary >= contentStart,
            asrBoundary < searchEnd,
            asrBoundary > removalStart
            else { continue }
            removalStart = asrBoundary
        }
        text.removeSubrange(removalStart..<text.endIndex)
        trimTrailingHorizontalWhitespace(in: &text)
    }

    private func makeLastParagraphABulletList(in text: inout String) {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            text = ""
            return
        }

        let boundary = text.range(of: "\n\n", options: .backwards)
        let paragraphStart = boundary?.upperBound ?? text.startIndex
        let prefix = boundary.map { String(text[..<$0.lowerBound]) } ?? ""
        let paragraph = String(text[paragraphStart...])
        let splitter = try! NSRegularExpression(pattern: #"(?<=[.!?;])[ \t]+|\n+"#)
        let normalized = splitter.stringByReplacingMatches(
            in: paragraph,
            range: NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph),
            withTemplate: "\n"
        )
        let items = normalized
            .split(separator: "\n")
            .map { item in
                String(item)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(
                        of: #"^[-*•][ \t]+"#,
                        with: "",
                        options: .regularExpression
                    )
            }
            .filter { !$0.isEmpty }

        guard !items.isEmpty else { return }
        let bullets = items.map { "- \($0)" }.joined(separator: "\n")
        text = prefix.isEmpty ? bullets : "\(prefix)\n\n\(bullets)"
    }
}

struct CleanupVocabularyProcessor: Sendable {
    let replacements: [CleanupVocabularyReplacement]
    let protectedPatterns: [CleanupProtectedPattern]

    init(
        replacements: [CleanupVocabularyReplacement] = [],
        protectedPatterns: [CleanupProtectedPattern] = CleanupProtectedPattern.standard
    ) {
        self.replacements = replacements
        self.protectedPatterns = protectedPatterns
    }

    func process(_ text: String) throws -> CleanupVocabularyResult {
        let replacementResult = try applyReplacements(to: text)
        let patternSpans = try protectedPatternSpans(in: replacementResult.text)
        let protectedSpans = coalesceOverlaps(
            replacementResult.protectedSpans + patternSpans,
            in: replacementResult.text
        )
        return CleanupVocabularyResult(
            text: replacementResult.text,
            appliedReplacements: replacementResult.applied,
            protectedSpans: protectedSpans
        )
    }

    private struct ReplacementMatch {
        let replacementIndex: Int
        let range: Range<String.Index>
        let byteRange: CleanupTextRange
    }

    private struct ReplacementStageResult {
        let text: String
        let applied: [CleanupAppliedVocabularyReplacement]
        let protectedSpans: [CleanupProtectedSpan]
    }

    private func applyReplacements(to text: String) throws -> ReplacementStageResult {
        var candidates: [ReplacementMatch] = []
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for (index, replacement) in replacements.enumerated() {
            let words = replacement.spokenForm.split(whereSeparator: \Character.isWhitespace)
            guard !words.isEmpty else { throw CleanupVocabularyError.emptySpokenForm(index: index) }
            let escaped = words
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[ \t]+"#)
            let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
            let options: NSRegularExpression.Options = replacement.isCaseSensitive ? [] : [.caseInsensitive]
            let expression = try! NSRegularExpression(pattern: pattern, options: options)
            for match in expression.matches(in: text, range: fullRange) {
                guard let range = Range(match.range, in: text) else { continue }
                candidates.append(
                    ReplacementMatch(
                        replacementIndex: index,
                        range: range,
                        byteRange: CleanupText.byteRange(in: text, for: range)
                    )
                )
            }
        }

        candidates.sort {
            if $0.byteRange.lowerBound != $1.byteRange.lowerBound {
                return $0.byteRange.lowerBound < $1.byteRange.lowerBound
            }
            if $0.byteRange.length != $1.byteRange.length {
                return $0.byteRange.length > $1.byteRange.length
            }
            return $0.replacementIndex < $1.replacementIndex
        }

        var selected: [ReplacementMatch] = []
        var consumedThrough = 0
        for candidate in candidates where candidate.byteRange.lowerBound >= consumedThrough {
            selected.append(candidate)
            consumedThrough = candidate.byteRange.upperBound
        }

        var output = ""
        var cursor = text.startIndex
        var applied: [CleanupAppliedVocabularyReplacement] = []
        var protectedSpans: [CleanupProtectedSpan] = []
        for match in selected {
            output.append(contentsOf: text[cursor..<match.range.lowerBound])
            let replacement = replacements[match.replacementIndex]
            let outputLower = output.utf8.count
            output.append(replacement.writtenForm)
            let outputRange = CleanupTextRange(outputLower, output.utf8.count)
            applied.append(
                CleanupAppliedVocabularyReplacement(
                    spokenForm: replacement.spokenForm,
                    writtenForm: replacement.writtenForm,
                    inputRange: match.byteRange,
                    outputRange: outputRange
                )
            )
            if replacement.isProtected {
                protectedSpans.append(
                    CleanupProtectedSpan(
                        name: "vocabulary:\(replacement.spokenForm)",
                        text: replacement.writtenForm,
                        range: outputRange
                    )
                )
            }
            cursor = match.range.upperBound
        }
        output.append(contentsOf: text[cursor...])
        return ReplacementStageResult(text: output, applied: applied, protectedSpans: protectedSpans)
    }

    private func protectedPatternSpans(in text: String) throws -> [CleanupProtectedSpan] {
        var spans: [CleanupProtectedSpan] = []
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in protectedPatterns {
            let options: NSRegularExpression.Options = pattern.isCaseInsensitive ? [.caseInsensitive] : []
            guard let expression = try? NSRegularExpression(pattern: pattern.expression, options: options) else {
                throw CleanupVocabularyError.invalidProtectedPattern(
                    name: pattern.name,
                    expression: pattern.expression
                )
            }
            for match in expression.matches(in: text, range: fullRange) {
                guard let range = Range(match.range, in: text), !range.isEmpty else { continue }
                spans.append(
                    CleanupProtectedSpan(
                        name: pattern.name,
                        text: String(text[range]),
                        range: CleanupText.byteRange(in: text, for: range)
                    )
                )
            }
        }
        return spans
    }

    /// Produces disjoint spans for the validator without dropping bytes covered
    /// by either match. Nested matches collapse to the larger match; partially
    /// overlapping matches become their exact source-byte union.
    private func coalesceOverlaps(
        _ spans: [CleanupProtectedSpan],
        in text: String
    ) -> [CleanupProtectedSpan] {
        let sorted = spans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return $0.name < $1.name
        }
        var result: [CleanupProtectedSpan] = []
        for span in sorted {
            guard let previous = result.last, previous.range.overlaps(span.range) else {
                result.append(span)
                continue
            }

            let mergedRange = CleanupTextRange(
                min(previous.range.lowerBound, span.range.lowerBound),
                max(previous.range.upperBound, span.range.upperBound)
            )
            let names = Set(
                (previous.name + "+" + span.name)
                    .split(separator: "+")
                    .map(String.init)
            )
            result[result.count - 1] = CleanupProtectedSpan(
                name: names.sorted().joined(separator: "+"),
                text: CleanupText.substring(in: text, range: mergedRange) ?? previous.text,
                range: mergedRange
            )
        }
        return result
    }
}

struct CleanupDisfluencyDetector: Sendable {
    private let highConfidenceFillers: Set<String> = ["um", "uh", "erm", "hmm"]
    private let possiblyIntentionalRepetitions: Set<String> = ["bye", "had", "no", "that", "very"]

    func candidates(
        in text: String,
        excluding protectedSpans: [CleanupProtectedSpan] = []
    ) -> [CleanupDisfluencyCandidate] {
        let tokens = CleanupText.lexicalTokens(in: text)
        var candidates: [CleanupDisfluencyCandidate] = []

        for token in tokens where highConfidenceFillers.contains(token.canonical) {
            addCandidate(
                CleanupDisfluencyCandidate(
                    kind: .filler,
                    confidence: .high,
                    text: token.text,
                    range: token.range
                ),
                to: &candidates,
                protectedSpans: protectedSpans
            )
        }

        let discourseMarkers: [([String], CleanupDisfluencyKind)] = [
            (["i", "mean"], .discourseMarker),
            (["you", "know"], .discourseMarker),
        ]
        for (words, kind) in discourseMarkers where tokens.count >= words.count {
            for start in 0...(tokens.count - words.count) {
                let slice = tokens[start..<(start + words.count)]
                guard Array(slice.map(\.canonical)) == words else { continue }
                let range = CleanupTextRange(slice.first!.range.lowerBound, slice.last!.range.upperBound)
                addCandidate(
                    CleanupDisfluencyCandidate(
                        kind: kind,
                        confidence: .possible,
                        text: CleanupText.substring(in: text, range: range) ?? words.joined(separator: " "),
                        range: range
                    ),
                    to: &candidates,
                    protectedSpans: protectedSpans
                )
            }
        }

        if tokens.count >= 2 {
            for index in 1..<tokens.count where tokens[index - 1].canonical == tokens[index].canonical {
                let gap = CleanupTextRange(tokens[index - 1].range.upperBound, tokens[index].range.lowerBound)
                let gapText = CleanupText.substring(in: text, range: gap) ?? ""
                guard gapText.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) == nil else {
                    continue
                }
                let confidence: CleanupDisfluencyConfidence = possiblyIntentionalRepetitions
                    .contains(tokens[index].canonical) ? .possible : .high
                addCandidate(
                    CleanupDisfluencyCandidate(
                        kind: .repetition,
                        confidence: confidence,
                        text: tokens[index].text,
                        range: tokens[index].range
                    ),
                    to: &candidates,
                    protectedSpans: protectedSpans
                )
            }
        }

        return candidates.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound < $1.range.upperBound
        }
    }

    private func addCandidate(
        _ candidate: CleanupDisfluencyCandidate,
        to candidates: inout [CleanupDisfluencyCandidate],
        protectedSpans: [CleanupProtectedSpan]
    ) {
        guard !protectedSpans.contains(where: { $0.range.overlaps(candidate.range) }),
              !candidates.contains(where: { $0.range == candidate.range })
        else { return }
        candidates.append(candidate)
    }
}
