import Foundation

/// Content only: no clipboard, Accessibility, persistence, or networking here.
struct RewriteSession {
    enum SourceKind: String { case clipboard, selection, dictation, manual }
    let id = UUID()
    var kind: SourceKind
    var original: String
    var versions: [String] = []
    var generatedVersions: [Bool] = []
    var versionIndex = -1
    var originalReturnIndex = -1
    var isReply = false

    var label: String { "Source: " + kind.rawValue }

    mutating func remember(_ text: String, generated: Bool = false) {
        guard !text.isEmpty else { return }
        if versionIndex >= 0, versions.indices.contains(versionIndex), versions[versionIndex] == text { return }
        if versionIndex >= 0, versionIndex + 1 < versions.count {
            generatedVersions.removeSubrange((versionIndex + 1)..<versions.count)
            versions.removeSubrange((versionIndex + 1)..<versions.count)
        }
        versions.append(text)
        generatedVersions.append(generated)
        if versions.count > 5 {
            generatedVersions.removeFirst(versions.count - 5)
            versions.removeFirst(versions.count - 5)
        }
        versionIndex = versions.count - 1
    }

    mutating func move(_ offset: Int) -> String? {
        let next = versionIndex == -1 && offset == 1
            ? (versions.indices.contains(originalReturnIndex) ? originalReturnIndex : versions.count - 1)
            : versionIndex + offset
        guard versions.indices.contains(next) else { return nil }
        versionIndex = next
        return versions[next]
    }
}
