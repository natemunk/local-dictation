import Darwin
import Foundation

struct OwnedModelManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let selection: ASRSelection
    let adapterVersion: String
    let sourceHost: String
    let payloadRelativePath: String
    let installedAt: Date

    init(
        selection: ASRSelection,
        adapterVersion: String,
        sourceHost: String,
        payloadRelativePath: String,
        installedAt: Date,
        schemaVersion: Int = OwnedModelManifest.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.selection = selection
        self.adapterVersion = adapterVersion
        self.sourceHost = sourceHost
        self.payloadRelativePath = payloadRelativePath
        self.installedAt = installedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selection
        case adapterVersion
        case sourceHost
        case payloadRelativePath
        case installedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        selection = try container.decode(ASRSelection.self, forKey: .selection)
        adapterVersion = try container.decode(String.self, forKey: .adapterVersion)
        sourceHost = try container.decode(String.self, forKey: .sourceHost)
        payloadRelativePath = try container.decode(String.self, forKey: .payloadRelativePath)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(selection, forKey: .selection)
        try container.encode(adapterVersion, forKey: .adapterVersion)
        try container.encode(sourceHost, forKey: .sourceHost)
        try container.encode(payloadRelativePath, forKey: .payloadRelativePath)
        try container.encode(installedAt, forKey: .installedAt)
    }
}

struct OwnedModelInstallation: Codable, Equatable, Sendable {
    let manifest: OwnedModelManifest
    let currentDirectory: URL
    let payloadURL: URL

    init(
        manifest: OwnedModelManifest,
        currentDirectory: URL,
        payloadURL: URL
    ) {
        self.manifest = manifest
        self.currentDirectory = currentDirectory
        self.payloadURL = payloadURL
    }

    init(
        manifest: OwnedModelManifest,
        directory: URL,
        payloadURL: URL
    ) {
        self.init(
            manifest: manifest,
            currentDirectory: directory,
            payloadURL: payloadURL
        )
    }

    var selection: ASRSelection { manifest.selection }
    var adapterVersion: String { manifest.adapterVersion }
    var sourceHost: String { manifest.sourceHost }
    var payloadRelativePath: String { manifest.payloadRelativePath }
    var installedAt: Date { manifest.installedAt }

    var directory: URL { currentDirectory }
    var modelURL: URL { payloadURL }
}

typealias ModelInstallation = OwnedModelInstallation

enum OwnedModelStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidManifest(String)
    case invalidPayloadPath(String)
    case missingManifest(URL)
    case missingPayload(URL)
    case stagingDirectoryMissing(URL)
    case stagingDirectoryNotOwned(URL)
    case currentDirectoryNotOwned(URL)
    case unsafePath(URL)
    case notDirectory(URL)
    case promotionFailed(String)
    case rollbackFailed(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason):
            "The Local Dictation model manifest is invalid: \(reason)"
        case .invalidPayloadPath(let path):
            "The Local Dictation model payload path is invalid: \(path)"
        case .missingManifest(let url):
            "The Local Dictation model manifest is missing at \(url.path)"
        case .missingPayload(let url):
            "The Local Dictation model payload is missing at \(url.path)"
        case .stagingDirectoryMissing(let url):
            "The Local Dictation model staging directory is missing at \(url.path)"
        case .stagingDirectoryNotOwned(let url):
            "The Local Dictation model staging directory is outside the owned staging area: \(url.path)"
        case .currentDirectoryNotOwned(let url):
            "The Local Dictation current model directory is not an owned directory: \(url.path)"
        case .unsafePath(let url):
            "The Local Dictation model path is unsafe: \(url.path)"
        case .notDirectory(let url):
            "The Local Dictation model path is not a directory: \(url.path)"
        case .promotionFailed(let reason):
            "The Local Dictation model promotion failed: \(reason)"
        case .rollbackFailed(let reason):
            "The Local Dictation model promotion failed and rollback was incomplete: \(reason)"
        case .fileSystem(let reason):
            "The Local Dictation model filesystem operation failed: \(reason)"
        }
    }
}

/// Owns only the versioned Local Dictation model directory.
///
/// A staging directory and the current directory always live below the same
/// adapter-version directory, so promotion is a same-filesystem move. The
/// previous current directory is moved into the selected install's quarantine
/// area until the caller explicitly resets that install.
actor OwnedModelStore {
    static let manifestFileName = "manifest.json"

    nonisolated static func defaultRootURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/LocalDictation/Models/v1",
                isDirectory: true
            )
    }

    let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = OwnedModelStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    // MARK: - Inspection

    func inspect(_ selection: ASRSelection) throws -> OwnedModelInstallation? {
        try currentInstallation(for: selection)
    }

    func inspect(selection: ASRSelection) throws -> OwnedModelInstallation? {
        try currentInstallation(for: selection)
    }

    func currentInstallation(for selection: ASRSelection) throws -> ModelInstallation? {
        guard try existingOwnedDirectory(at: rootURL) else { return nil }

        let current = currentDirectory(for: selection)
        guard !isSymbolicLink(current) else {
            throw OwnedModelStoreError.currentDirectoryNotOwned(current)
        }
        guard fileManager.fileExists(atPath: current.path) else { return nil }
        guard isDirectory(current) else {
            throw OwnedModelStoreError.currentDirectoryNotOwned(current)
        }

        let manifestURL = current.appendingPathComponent(Self.manifestFileName)
        guard !isSymbolicLink(manifestURL) else {
            throw OwnedModelStoreError.unsafePath(manifestURL)
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw OwnedModelStoreError.missingManifest(manifestURL)
        }

        let manifest: OwnedModelManifest
        do {
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            manifest = try JSONDecoder().decode(OwnedModelManifest.self, from: data)
        } catch let error as OwnedModelStoreError {
            throw error
        } catch {
            throw OwnedModelStoreError.invalidManifest(error.localizedDescription)
        }

        let payloadURL = try validate(
            manifest: manifest,
            for: selection,
            in: current,
            manifestURL: manifestURL
        )
        return OwnedModelInstallation(
            manifest: manifest,
            currentDirectory: current,
            payloadURL: payloadURL
        )
    }

    func currentInstallation(_ selection: ASRSelection) throws -> OwnedModelInstallation? {
        try currentInstallation(for: selection)
    }

    // MARK: - Staging and promotion

    func makeStagingDirectory(for selection: ASRSelection) throws -> URL {
        let versionRoot = try ensureVersionRoot(for: selection)
        let stagingRoot = versionRoot.appendingPathComponent("staging", isDirectory: true)
        try ensureDirectory(at: stagingRoot)
        return try makeUniqueDirectory(in: stagingRoot)
    }

    func makeStagingDirectory(_ selection: ASRSelection) throws -> URL {
        try makeStagingDirectory(for: selection)
    }

    @discardableResult
    func promote(
        stagingDirectory: URL,
        for selection: ASRSelection,
        payloadRelativePath: String,
        sourceHost: String = "huggingface.co",
        installedAt: Date = Date()
    ) throws -> OwnedModelInstallation {
        let versionRoot = try ensureVersionRoot(for: selection)
        let staging = try validateStagingDirectory(
            stagingDirectory,
            for: selection,
            versionRoot: versionRoot
        )
        _ = try validatePayload(
            relativePath: payloadRelativePath,
            in: staging
        )
        guard sourceHost == selection.sourceHost else {
            throw OwnedModelStoreError.invalidManifest(
                "sourceHost does not match the selected model"
            )
        }

        let manifest = OwnedModelManifest(
            selection: selection,
            adapterVersion: selection.adapterVersion,
            sourceHost: sourceHost,
            payloadRelativePath: payloadRelativePath,
            installedAt: installedAt
        )
        let manifestURL = staging.appendingPathComponent(Self.manifestFileName)
        try writeManifest(manifest, to: manifestURL)
        _ = try validate(
            manifest: manifest,
            for: selection,
            in: staging,
            manifestURL: manifestURL
        )

        let current = versionRoot.appendingPathComponent("current", isDirectory: true)
        guard !isSymbolicLink(current) else {
            throw OwnedModelStoreError.currentDirectoryNotOwned(current)
        }
        if fileManager.fileExists(atPath: current.path), !isDirectory(current) {
            throw OwnedModelStoreError.currentDirectoryNotOwned(current)
        }

        if fileManager.fileExists(atPath: current.path) {
            let quarantineRoot = versionRoot.appendingPathComponent(
                "quarantine",
                isDirectory: true
            )
            try ensureDirectory(at: quarantineRoot)
            let previousCurrent = try makeUniquePath(in: quarantineRoot)
            let swapStatus = renamex_np(
                staging.path,
                current.path,
                UInt32(RENAME_SWAP)
            )
            guard swapStatus == 0 else {
                throw OwnedModelStoreError.promotionFailed(
                    String(cString: strerror(errno))
                )
            }

            // `current` became the new install atomically and `staging` now
            // names the prior install. Preserve that old generation in this
            // selection's quarantine. If the secondary move fails, swap back
            // atomically so callers never observe a half-promoted state.
            do {
                try fileManager.moveItem(at: staging, to: previousCurrent)
            } catch {
                let rollbackStatus = renamex_np(
                    staging.path,
                    current.path,
                    UInt32(RENAME_SWAP)
                )
                if rollbackStatus == 0 {
                    throw OwnedModelStoreError.promotionFailed(
                        "could not quarantine the previous install: \(error.localizedDescription)"
                    )
                }
                // The new current is valid and the old install remains
                // recoverable at the UUID staging path. Do not report failure:
                // caller cleanup after an error could otherwise erase it.
            }
        } else {
            // Same-filesystem rename is atomic for the first installation.
            do {
                try fileManager.moveItem(at: staging, to: current)
            } catch {
                throw OwnedModelStoreError.promotionFailed(error.localizedDescription)
            }
        }

        return OwnedModelInstallation(
            manifest: manifest,
            currentDirectory: current,
            payloadURL: current.appendingPathComponent(
                manifest.payloadRelativePath,
                isDirectory: false
            )
        )
    }

    func promote(
        stagingDirectory: URL,
        selection: ASRSelection,
        payloadRelativePath: String,
        sourceHost: String = "huggingface.co",
        installedAt: Date = Date()
    ) throws -> OwnedModelInstallation {
        try promote(
            stagingDirectory: stagingDirectory,
            for: selection,
            payloadRelativePath: payloadRelativePath,
            sourceHost: sourceHost,
            installedAt: installedAt
        )
    }

    func promote(
        _ stagingDirectory: URL,
        for selection: ASRSelection,
        payloadRelativePath: String,
        sourceHost: String = "huggingface.co",
        installedAt: Date = Date()
    ) throws -> OwnedModelInstallation {
        try promote(
            stagingDirectory: stagingDirectory,
            for: selection,
            payloadRelativePath: payloadRelativePath,
            sourceHost: sourceHost,
            installedAt: installedAt
        )
    }

    // MARK: - Owned cleanup and repair

    func quarantineCurrent(
        for selection: ASRSelection,
        reason: String? = nil
    ) throws -> URL? {
        _ = reason
        guard try existingOwnedDirectory(at: rootURL) else { return nil }

        let versionRoot = try existingVersionRoot(for: selection)
        guard let versionRoot else { return nil }
        let current = versionRoot.appendingPathComponent("current", isDirectory: true)
        guard !isSymbolicLink(current) else {
            throw OwnedModelStoreError.currentDirectoryNotOwned(current)
        }
        guard fileManager.fileExists(atPath: current.path) else { return nil }
        guard isDirectory(current) else {
            throw OwnedModelStoreError.currentDirectoryNotOwned(current)
        }

        let quarantineRoot = versionRoot.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        try ensureDirectory(at: quarantineRoot)
        let destination = try makeUniquePath(in: quarantineRoot)
        do {
            try fileManager.moveItem(at: current, to: destination)
        } catch {
            throw OwnedModelStoreError.fileSystem(error.localizedDescription)
        }
        return destination
    }

    func quarantineCurrent(selection: ASRSelection) throws -> URL? {
        try quarantineCurrent(for: selection)
    }

    func quarantine(_ selection: ASRSelection) throws -> URL? {
        try quarantineCurrent(for: selection)
    }

    /// Discards one UUID-named staging directory after resolving its path to a
    /// known selection/version below this store's root.
    func discardStaging(_ stagingDirectory: URL) {
        let staging = stagingDirectory.standardizedFileURL
        for selection in ASRSelection.allCases {
            let expectedRoot = stagingRoot(for: selection).standardizedFileURL
            guard staging.deletingLastPathComponent() == expectedRoot else { continue }
            try? discardStaging(stagingDirectory, for: selection)
            return
        }
    }

    func discardStaging(_ stagingDirectory: URL, for selection: ASRSelection) throws {
        guard try existingOwnedDirectory(at: rootURL) else { return }
        guard let versionRoot = try existingVersionRoot(for: selection) else { return }
        let stagingRoot = versionRoot.appendingPathComponent("staging", isDirectory: true)
        guard try existingOwnedDirectory(at: stagingRoot) else { return }

        let staging = try validateStagingLocation(
            stagingDirectory,
            stagingRoot: stagingRoot,
            versionRoot: versionRoot
        )
        guard fileManager.fileExists(atPath: staging.path) else { return }
        guard isDirectory(staging) else {
            throw OwnedModelStoreError.stagingDirectoryNotOwned(staging)
        }
        do {
            try fileManager.removeItem(at: staging)
        } catch {
            throw OwnedModelStoreError.fileSystem(error.localizedDescription)
        }
    }

    func discardStagingDirectory(_ stagingDirectory: URL, for selection: ASRSelection) throws {
        try discardStaging(stagingDirectory, for: selection)
    }

    /// Quarantines a malformed current install so it can be replaced without
    /// deleting the user's last owned model payload.
    func repair(for selection: ASRSelection) throws -> OwnedModelInstallation? {
        do {
            return try currentInstallation(for: selection)
        } catch let error as OwnedModelStoreError where error.isRepairable {
            _ = try quarantineCurrent(for: selection)
            return nil
        }
    }

    func repair(_ selection: ASRSelection) throws -> OwnedModelInstallation? {
        try repair(for: selection)
    }

    /// Removes only the selected model's adapter-version directory.
    func resetInstallation(for selection: ASRSelection) throws {
        guard try existingOwnedDirectory(at: rootURL) else { return }

        let selectionRoot = rootURL.appendingPathComponent(
            selection.storageName,
            isDirectory: true
        )
        guard !isSymbolicLink(selectionRoot) else {
            throw OwnedModelStoreError.unsafePath(selectionRoot)
        }
        guard fileManager.fileExists(atPath: selectionRoot.path) else { return }
        guard isDirectory(selectionRoot) else {
            throw OwnedModelStoreError.notDirectory(selectionRoot)
        }

        let versionRoot = selectionRoot.appendingPathComponent(
            selection.adapterVersion,
            isDirectory: true
        )
        guard !isSymbolicLink(versionRoot) else {
            throw OwnedModelStoreError.unsafePath(versionRoot)
        }
        guard fileManager.fileExists(atPath: versionRoot.path) else { return }
        guard isDirectory(versionRoot) else {
            throw OwnedModelStoreError.notDirectory(versionRoot)
        }
        do {
            try fileManager.removeItem(at: versionRoot)
        } catch {
            throw OwnedModelStoreError.fileSystem(error.localizedDescription)
        }
    }

    func reset(_ selection: ASRSelection) throws {
        try resetInstallation(for: selection)
    }

    func reset(for selection: ASRSelection) throws {
        try resetInstallation(for: selection)
    }

    // MARK: - Layout helpers

    func currentDirectory(for selection: ASRSelection) -> URL {
        versionRoot(for: selection).appendingPathComponent("current", isDirectory: true)
    }

    func stagingRoot(for selection: ASRSelection) -> URL {
        versionRoot(for: selection).appendingPathComponent("staging", isDirectory: true)
    }

    func quarantineRoot(for selection: ASRSelection) -> URL {
        versionRoot(for: selection).appendingPathComponent("quarantine", isDirectory: true)
    }

    // MARK: - Validation helpers

    private func ensureVersionRoot(for selection: ASRSelection) throws -> URL {
        try ensureDirectory(at: rootURL)
        let selectionRoot = rootURL.appendingPathComponent(
            selection.storageName,
            isDirectory: true
        )
        try ensureDirectory(at: selectionRoot)
        let versionRoot = selectionRoot.appendingPathComponent(
            selection.adapterVersion,
            isDirectory: true
        )
        try ensureDirectory(at: versionRoot)
        return versionRoot
    }

    private func existingVersionRoot(for selection: ASRSelection) throws -> URL? {
        let selectionRoot = rootURL.appendingPathComponent(
            selection.storageName,
            isDirectory: true
        )
        guard !isSymbolicLink(selectionRoot) else {
            throw OwnedModelStoreError.unsafePath(selectionRoot)
        }
        guard fileManager.fileExists(atPath: selectionRoot.path) else { return nil }
        guard isDirectory(selectionRoot) else {
            throw OwnedModelStoreError.notDirectory(selectionRoot)
        }

        let versionRoot = selectionRoot.appendingPathComponent(
            selection.adapterVersion,
            isDirectory: true
        )
        guard !isSymbolicLink(versionRoot) else {
            throw OwnedModelStoreError.unsafePath(versionRoot)
        }
        guard fileManager.fileExists(atPath: versionRoot.path) else { return nil }
        guard isDirectory(versionRoot) else {
            throw OwnedModelStoreError.notDirectory(versionRoot)
        }
        return versionRoot
    }

    private func versionRoot(for selection: ASRSelection) -> URL {
        rootURL
            .appendingPathComponent(selection.storageName, isDirectory: true)
            .appendingPathComponent(selection.adapterVersion, isDirectory: true)
    }

    private func validateStagingDirectory(
        _ stagingDirectory: URL,
        for selection: ASRSelection,
        versionRoot: URL
    ) throws -> URL {
        let stagingRoot = versionRoot.appendingPathComponent("staging", isDirectory: true)
        guard try existingOwnedDirectory(at: stagingRoot) else {
            throw OwnedModelStoreError.stagingDirectoryMissing(stagingRoot)
        }
        return try validateStagingLocation(
            stagingDirectory,
            stagingRoot: stagingRoot,
            versionRoot: versionRoot
        )
    }

    private func validateStagingLocation(
        _ stagingDirectory: URL,
        stagingRoot: URL,
        versionRoot: URL
    ) throws -> URL {
        let staging = stagingDirectory.standardizedFileURL
        guard staging.deletingLastPathComponent() == stagingRoot.standardizedFileURL,
              UUID(uuidString: staging.lastPathComponent) != nil,
              isContained(staging, in: versionRoot)
        else {
            throw OwnedModelStoreError.stagingDirectoryNotOwned(staging)
        }
        guard !isSymbolicLink(staging) else {
            throw OwnedModelStoreError.unsafePath(staging)
        }
        guard fileManager.fileExists(atPath: staging.path) else {
            throw OwnedModelStoreError.stagingDirectoryMissing(staging)
        }
        guard isDirectory(staging) else {
            throw OwnedModelStoreError.stagingDirectoryNotOwned(staging)
        }
        guard isContained(staging, in: stagingRoot, resolvingSymlinks: true) else {
            throw OwnedModelStoreError.unsafePath(staging)
        }
        return staging
    }

    private func validatePayload(relativePath: String, in directory: URL) throws -> URL {
        guard isSafeRelativePath(relativePath) else {
            throw OwnedModelStoreError.invalidPayloadPath(relativePath)
        }

        let payloadURL = directory.appendingPathComponent(relativePath, isDirectory: false)
        guard isContained(payloadURL, in: directory) else {
            throw OwnedModelStoreError.invalidPayloadPath(relativePath)
        }
        guard !isSymbolicLink(payloadURL) else {
            throw OwnedModelStoreError.unsafePath(payloadURL)
        }
        guard fileManager.fileExists(atPath: payloadURL.path) else {
            throw OwnedModelStoreError.missingPayload(payloadURL)
        }
        guard isContained(payloadURL, in: directory, resolvingSymlinks: true) else {
            throw OwnedModelStoreError.unsafePath(payloadURL)
        }
        return payloadURL
    }

    private func validate(
        manifest: OwnedModelManifest,
        for selection: ASRSelection,
        in directory: URL,
        manifestURL: URL
    ) throws -> URL {
        guard manifest.schemaVersion == OwnedModelManifest.currentSchemaVersion else {
            throw OwnedModelStoreError.invalidManifest(
                "unsupported schema version \(manifest.schemaVersion)"
            )
        }
        guard manifest.selection == selection else {
            throw OwnedModelStoreError.invalidManifest(
                "selection does not match the owned directory"
            )
        }
        guard manifest.adapterVersion == selection.adapterVersion else {
            throw OwnedModelStoreError.invalidManifest(
                "adapterVersion does not match the selected model"
            )
        }
        guard manifest.sourceHost == selection.sourceHost else {
            throw OwnedModelStoreError.invalidManifest(
                "sourceHost does not match the selected model"
            )
        }
        guard !isSymbolicLink(manifestURL),
              fileManager.fileExists(atPath: manifestURL.path)
        else {
            throw OwnedModelStoreError.missingManifest(manifestURL)
        }

        do {
            return try validatePayload(
                relativePath: manifest.payloadRelativePath,
                in: directory
            )
        } catch let error as OwnedModelStoreError {
            throw error
        } catch {
            throw OwnedModelStoreError.invalidManifest(error.localizedDescription)
        }
    }

    private func writeManifest(
        _ manifest: OwnedModelManifest,
        to manifestURL: URL
    ) throws {
        guard !isSymbolicLink(manifestURL) else {
            throw OwnedModelStoreError.unsafePath(manifestURL)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: [.atomic])
        } catch let error as OwnedModelStoreError {
            throw error
        } catch {
            throw OwnedModelStoreError.fileSystem(error.localizedDescription)
        }
    }

    private func ensureDirectory(at url: URL) throws {
        if isSymbolicLink(url) {
            throw OwnedModelStoreError.unsafePath(url)
        }
        if fileManager.fileExists(atPath: url.path) {
            guard isDirectory(url) else {
                throw OwnedModelStoreError.notDirectory(url)
            }
            return
        }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch {
            throw OwnedModelStoreError.fileSystem(error.localizedDescription)
        }
        guard !isSymbolicLink(url), isDirectory(url) else {
            throw OwnedModelStoreError.unsafePath(url)
        }
    }

    private func existingOwnedDirectory(at url: URL) throws -> Bool {
        if isSymbolicLink(url) {
            throw OwnedModelStoreError.unsafePath(url)
        }
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard isDirectory(url) else {
            throw OwnedModelStoreError.notDirectory(url)
        }
        return true
    }

    private func makeUniqueDirectory(in parent: URL) throws -> URL {
        let candidate = try makeUniquePath(in: parent)
        do {
            try fileManager.createDirectory(
                at: candidate,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch {
            throw OwnedModelStoreError.fileSystem(error.localizedDescription)
        }
        guard !isSymbolicLink(candidate), isDirectory(candidate) else {
            throw OwnedModelStoreError.unsafePath(candidate)
        }
        return candidate
    }

    private func makeUniquePath(in parent: URL) throws -> URL {
        for _ in 0..<10 {
            let candidate = parent.appendingPathComponent(
                UUID().uuidString.lowercased(),
                isDirectory: true
            )
            guard !isSymbolicLink(candidate),
                  !fileManager.fileExists(atPath: candidate.path)
            else { continue }
            return candidate
        }
        throw OwnedModelStoreError.fileSystem("could not allocate a UUID directory")
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }

    private func isContained(
        _ candidate: URL,
        in parent: URL,
        resolvingSymlinks: Bool = false
    ) -> Bool {
        let candidateURL = resolvingSymlinks
            ? candidate.resolvingSymlinksInPath().standardizedFileURL
            : candidate.standardizedFileURL
        let parentURL = resolvingSymlinks
            ? parent.resolvingSymlinksInPath().standardizedFileURL
            : parent.standardizedFileURL
        let parentPath = parentURL.path.hasSuffix("/")
            ? parentURL.path
            : parentURL.path + "/"
        return candidateURL.path == parentURL.path || candidateURL.path.hasPrefix(parentPath)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else { return false }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

private extension OwnedModelStoreError {
    var isRepairable: Bool {
        switch self {
        case .invalidManifest, .invalidPayloadPath, .missingManifest, .missingPayload, .unsafePath:
            true
        default:
            false
        }
    }
}
