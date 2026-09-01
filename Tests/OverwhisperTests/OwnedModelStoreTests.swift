import Foundation
import Testing
@testable import LocalDictation

@Suite("Owned model store")
struct OwnedModelStoreTests {
    @Test("missing installation is reported as absent")
    func missingInstallation() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try await store.currentInstallation(for: .parakeetV2) == nil)
    }

    @Test("promotion writes a manifest and current installation can be read")
    func validPromotionAndRead() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.parakeetV2
        let staging = try await store.makeStagingDirectory(for: selection)
        let payloadRelativePath = "payload/model.bin"
        try writePayload(at: staging.appendingPathComponent(payloadRelativePath))
        let installedAt = Date(timeIntervalSinceReferenceDate: 1234)

        let promoted = try await store.promote(
            stagingDirectory: staging,
            for: selection,
            payloadRelativePath: payloadRelativePath,
            sourceHost: selection.sourceHost,
            installedAt: installedAt
        )
        let current = try #require(await store.currentInstallation(for: selection))

        #expect(promoted == current)
        #expect(current.manifest.schemaVersion == OwnedModelManifest.currentSchemaVersion)
        #expect(current.manifest.selection == selection)
        #expect(current.manifest.adapterVersion == selection.adapterVersion)
        #expect(current.manifest.sourceHost == selection.sourceHost)
        #expect(current.manifest.payloadRelativePath == payloadRelativePath)
        #expect(current.manifest.installedAt == installedAt)
        #expect(FileManager.default.fileExists(atPath: current.payloadURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: current.currentDirectory
                    .appendingPathComponent(OwnedModelStore.manifestFileName)
                    .path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(root.path.contains("local-dictation-owned-models-"))
    }

    @Test("wrong selection or adapter version manifests are rejected")
    func wrongManifestMetadataIsRejected() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.parakeetV2
        let staging = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: staging.appendingPathComponent("model.bin"))
        _ = try await store.promote(
            stagingDirectory: staging,
            for: selection,
            payloadRelativePath: "model.bin",
            sourceHost: selection.sourceHost
        )
        let current = await store.currentDirectory(for: selection)
        let manifestURL = current.appendingPathComponent(OwnedModelStore.manifestFileName)

        let wrongSelection = OwnedModelManifest(
            selection: .parakeetV3,
            adapterVersion: ASRSelection.parakeetV3.adapterVersion,
            sourceHost: ASRSelection.parakeetV3.sourceHost,
            payloadRelativePath: "model.bin",
            installedAt: Date()
        )
        try writeManifest(wrongSelection, to: manifestURL)
        await #expect(throws: OwnedModelStoreError.self) {
            try await store.inspect(.parakeetV2)
        }

        let wrongVersion = OwnedModelManifest(
            selection: .parakeetV2,
            adapterVersion: "whisperkit-0.15.0",
            sourceHost: selection.sourceHost,
            payloadRelativePath: "model.bin",
            installedAt: Date()
        )
        try writeManifest(wrongVersion, to: manifestURL)
        await #expect(throws: OwnedModelStoreError.self) {
            try await store.currentInstallation(for: .parakeetV2)
        }
    }

    @Test("promotion rejects a missing payload")
    func missingPayloadIsRejected() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.parakeetV2
        let staging = try await store.makeStagingDirectory(for: selection)
        await #expect(throws: OwnedModelStoreError.self) {
            try await store.promote(
                stagingDirectory: staging,
                for: selection,
                payloadRelativePath: "model.bin",
                sourceHost: selection.sourceHost
            )
        }
        #expect(try await store.currentInstallation(for: selection) == nil)
    }

    @Test("promotion rejects absolute and traversal payload paths")
    func payloadPathTraversalIsRejected() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.parakeetV2
        let staging = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: staging.appendingPathComponent("model.bin"))

        for path in ["../model.bin", "/tmp/model.bin", "payload/../model.bin"] {
            await #expect(throws: OwnedModelStoreError.self) {
                try await store.promote(
                    stagingDirectory: staging,
                    for: selection,
                    payloadRelativePath: path,
                    sourceHost: selection.sourceHost
                )
            }
        }
    }

    @Test("failed promotion preserves the previous current installation")
    func failedPromotionPreservesOldInstallation() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.parakeetV2
        let firstStaging = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: firstStaging.appendingPathComponent("old/model.bin"))
        let old = try await store.promote(
            stagingDirectory: firstStaging,
            for: selection,
            payloadRelativePath: "old/model.bin",
            sourceHost: selection.sourceHost,
            installedAt: Date(timeIntervalSinceReferenceDate: 1)
        )

        let failedStaging = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: failedStaging.appendingPathComponent("new/model.bin"))
        await #expect(throws: OwnedModelStoreError.self) {
            try await store.promote(
                stagingDirectory: failedStaging,
                for: selection,
                payloadRelativePath: "../old/model.bin",
                sourceHost: selection.sourceHost
            )
        }

        let current = try #require(await store.currentInstallation(for: selection))
        #expect(current == old)
        #expect(FileManager.default.fileExists(atPath: old.payloadURL.path))
    }

    @Test("replacement promotion atomically installs new and quarantines old")
    func replacementPromotionQuarantinesOld() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.parakeetV2
        let first = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: first.appendingPathComponent("old/model.bin"))
        _ = try await store.promote(
            stagingDirectory: first,
            for: selection,
            payloadRelativePath: "old/model.bin",
            sourceHost: selection.sourceHost,
            installedAt: Date(timeIntervalSinceReferenceDate: 1)
        )

        let replacement = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: replacement.appendingPathComponent("new/model.bin"))
        let current = try await store.promote(
            stagingDirectory: replacement,
            for: selection,
            payloadRelativePath: "new/model.bin",
            sourceHost: selection.sourceHost,
            installedAt: Date(timeIntervalSinceReferenceDate: 2)
        )

        #expect(current.payloadRelativePath == "new/model.bin")
        #expect(FileManager.default.fileExists(atPath: current.payloadURL.path))
        let quarantine = await store.quarantineRoot(for: selection)
        let generations = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        #expect(generations.count == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: generations[0].appendingPathComponent("old/model.bin").path
            )
        )
    }

    @Test("quarantine moves only the selected owned installation")
    func quarantineIsScopedToSelection() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = ASRSelection.parakeetV2
        let sibling = ASRSelection.whisperSmallEn
        _ = try await promoteSimple(selected, in: store)
        let siblingInstallation = try await promoteSimple(sibling, in: store)
        let externalMarker = root.deletingLastPathComponent()
            .appendingPathComponent("external-model-marker-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: externalMarker)
        defer { try? FileManager.default.removeItem(at: externalMarker) }

        let quarantineURL = try #require(
            await store.quarantineCurrent(for: selected, reason: "test replacement")
        )
        #expect(UUID(uuidString: quarantineURL.lastPathComponent) != nil)
        #expect(try await store.currentInstallation(for: selected) == nil)
        #expect(try await store.currentInstallation(for: sibling) == siblingInstallation)
        #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
        #expect(FileManager.default.fileExists(atPath: externalMarker.path))
    }

    @Test("reset removes only the selected install and leaves siblings and markers")
    func resetIsScopedToSelection() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = ASRSelection.parakeetV2
        let sibling = ASRSelection.parakeetV3
        _ = try await promoteSimple(selected, in: store)
        let siblingInstallation = try await promoteSimple(sibling, in: store)
        let externalMarker = root.deletingLastPathComponent()
            .appendingPathComponent("external-marker-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: externalMarker)
        defer { try? FileManager.default.removeItem(at: externalMarker) }

        try await store.resetInstallation(for: selected)

        #expect(try await store.currentInstallation(for: selected) == nil)
        #expect(try await store.currentInstallation(for: sibling) == siblingInstallation)
        #expect(FileManager.default.fileExists(atPath: externalMarker.path))
    }

    @Test("staging can be discarded only through the selected owned area")
    func discardStaging() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = ASRSelection.whisperLargeV3Turbo
        let staging = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: staging.appendingPathComponent("model.bin"))
        await store.discardStaging(staging)

        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await store.currentInstallation(for: selection) == nil)
    }

    private func makeStore() throws -> (URL, OwnedModelStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "local-dictation-owned-models-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, OwnedModelStore(rootURL: root))
    }

    private func promoteSimple(
        _ selection: ASRSelection,
        in store: OwnedModelStore
    ) async throws -> ModelInstallation {
        let staging = try await store.makeStagingDirectory(for: selection)
        try writePayload(at: staging.appendingPathComponent("model.bin"))
        return try await store.promote(
            stagingDirectory: staging,
            for: selection,
            payloadRelativePath: "model.bin",
            sourceHost: selection.sourceHost
        )
    }

    private func writePayload(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("synthetic model payload".utf8).write(to: url)
    }

    private func writeManifest(_ manifest: OwnedModelManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }
}
