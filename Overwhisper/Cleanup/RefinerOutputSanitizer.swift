import Foundation

enum RefinerOutputSanitizerError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedWrapper
    case unsafeControlCharacter(UInt32)
    case excessiveOutput(actualUTF8Count: Int, maximumUTF8Count: Int)

    var description: String {
        switch self {
        case .unsupportedWrapper:
            "The refiner returned an explanation or malformed Markdown wrapper instead of only cleaned text."
        case let .unsafeControlCharacter(value):
            "The refiner returned an unsafe control character (U+\(String(value, radix: 16, uppercase: true)))."
        case let .excessiveOutput(actual, maximum):
            "The refiner returned \(actual) UTF-8 bytes; the conservative limit for this transcript is \(maximum)."
        }
    }
}

enum RefinerOutputSanitizer {
    static func sanitize(_ output: String, sourceUTF8Count: Int) throws -> String {
        let maximumUTF8Count = max(4_096, sourceUTF8Count * 4 + 1_024)
        guard output.utf8.count <= maximumUTF8Count else {
            throw RefinerOutputSanitizerError.excessiveOutput(
                actualUTF8Count: output.utf8.count,
                maximumUTF8Count: maximumUTF8Count
            )
        }
        var normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while normalized.first == "\u{FEFF}" {
            normalized.removeFirst()
        }
        try rejectUnsafeScalars(in: normalized)
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.contains("```") else { return normalized }
        guard normalized.hasPrefix("```"), normalized.hasSuffix("```") else {
            throw RefinerOutputSanitizerError.unsupportedWrapper
        }
        guard let openingLineEnd = normalized.firstIndex(of: "\n") else {
            throw RefinerOutputSanitizerError.unsupportedWrapper
        }

        let openingLine = normalized[..<openingLineEnd]
        let language = openingLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard language.allSatisfy({
            $0.isLetter || $0.isNumber || "_+.-".contains($0)
        }) else {
            throw RefinerOutputSanitizerError.unsupportedWrapper
        }

        let closingStart = normalized.index(normalized.endIndex, offsetBy: -3)
        guard closingStart > openingLineEnd,
              normalized[normalized.index(before: closingStart)] == "\n"
        else {
            throw RefinerOutputSanitizerError.unsupportedWrapper
        }

        let contentStart = normalized.index(after: openingLineEnd)
        let content = String(normalized[contentStart..<closingStart])
        guard !content.contains("```") else {
            throw RefinerOutputSanitizerError.unsupportedWrapper
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rejectUnsafeScalars(in text: String) throws {
        let explicitlyUnsafe: Set<UInt32> = [
            0x200B, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
            0xFEFF,
        ]
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let disallowedC0 = value < 0x20 && value != 0x09 && value != 0x0A
            if disallowedC0 || value == 0x7F || explicitlyUnsafe.contains(value) {
                throw RefinerOutputSanitizerError.unsafeControlCharacter(value)
            }
        }
    }
}
