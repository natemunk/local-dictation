import Foundation

struct CorpusErrorSanitizer: Sendable {
    private let replacements: [(path: String, label: String)]

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        modelRootURL: URL,
        manifestDirectoryURL: URL
    ) {
        let pairs = [
            (modelRootURL.standardizedFileURL.path, "<model-root>"),
            (manifestDirectoryURL.standardizedFileURL.path, "<manifest-dir>"),
            (homeURL.standardizedFileURL.path, "<home>"),
        ]
        replacements = pairs
            .filter { !$0.0.isEmpty && $0.0 != "/" }
            .sorted { $0.0.count > $1.0.count }
    }

    func sanitize(
        _ message: String,
        audioURL: URL? = nil,
        manifestAudioPath: String? = nil
    ) -> String {
        var sanitized = message.replacingOccurrences(of: "file://", with: "")
        if let audioURL, let manifestAudioPath {
            sanitized = sanitized.replacingOccurrences(
                of: audioURL.standardizedFileURL.path,
                with: manifestAudioPath
            )
        }
        for replacement in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: replacement.path,
                with: replacement.label
            )
        }
        sanitized = sanitized.replacingOccurrences(
            of: #"/Users/[^/\s:]+"#,
            with: "<home>",
            options: .regularExpression
        )
        sanitized = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if sanitized.count > 2_048 {
            let end = sanitized.index(sanitized.startIndex, offsetBy: 2_048)
            sanitized = String(sanitized[..<end]) + "…"
        }
        return sanitized
    }
}
