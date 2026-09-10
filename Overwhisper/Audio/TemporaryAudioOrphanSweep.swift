import Foundation

/// Only files observed before this process began recording are candidates.
/// A deferred sweep never enumerates current recordings, and a changed file
/// is left alone (for example, a replay using the same remote request UUID).
enum TemporaryAudioOrphanSweep {
    struct Candidate: Sendable {
        let url: URL
        let modifiedAt: Date
        let createdAt: Date?
        let size: Int?
    }

    static let minimumAge: TimeInterval = 60 * 60
    private static let prefixes = ["local_dictation_recording_", "local-dictation-iphone-"]
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        .creationDateKey, .fileSizeKey,
    ]

    static func capture(in directory: URL) -> [Candidate] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        return files.compactMap { url in
            guard prefixes.contains(where: url.lastPathComponent.hasPrefix),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate
            else { return nil }
            return Candidate(url: url, modifiedAt: modified, createdAt: values.creationDate, size: values.fileSize)
        }
    }

    @discardableResult
    static func removeEligible(_ candidates: [Candidate], now: Date = Date()) -> [Candidate] {
        var deferred: [Candidate] = []
        for candidate in candidates {
            var currentURL = candidate.url
            currentURL.removeAllCachedResourceValues()
            guard let values = try? currentURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  values.contentModificationDate == candidate.modifiedAt,
                  values.creationDate == candidate.createdAt,
                  values.fileSize == candidate.size
            else { continue }
            guard now.timeIntervalSince(candidate.modifiedAt) >= minimumAge else {
                deferred.append(candidate)
                continue
            }
            try? FileManager.default.removeItem(at: candidate.url)
        }
        return deferred
    }
}
