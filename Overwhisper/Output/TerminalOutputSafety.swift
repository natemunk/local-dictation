import Foundation

enum TerminalOutputSafety {
    /// Automatic terminal insertion must never contain a line-break character,
    /// because many shells interpret pasted newlines as submissions.
    static func collapseLineBreaks(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
