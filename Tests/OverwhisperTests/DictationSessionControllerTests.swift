import Foundation
import Testing
@testable import LocalDictation

@Suite("Dictation session ownership")
@MainActor
struct DictationSessionControllerTests {
    @Test("a stale generation cannot mutate or clear the active session")
    func rejectsStaleGeneration() throws {
        let controller = DictationSessionController()
        let stale = token(generation: 1)
        let current = token(generation: 2)
        controller.install(session(for: current))

        #expect(!controller.update(stale) { $0.rawText = "stale" })
        #expect(controller.clear(stale) == nil)
        #expect(controller.active?.token == current)
        #expect(controller.active?.rawText.isEmpty == true)
    }

    @Test("cancellation makes a matching generation non-current")
    func cancellationInvalidatesCurrentWork() throws {
        let controller = DictationSessionController()
        let token = token(generation: 8)
        controller.install(session(for: token))

        #expect(controller.matches(token))
        #expect(controller.isCurrent(token))
        #expect(controller.update(token) { $0.cancellationRequested = true })
        #expect(controller.matches(token))
        #expect(!controller.isCurrent(token))
    }

    @Test("clear returns the owned generation exactly once")
    func clearsExactlyOnce() throws {
        let controller = DictationSessionController()
        let token = token(generation: 13)
        controller.install(session(for: token))

        #expect(controller.clear(token)?.token == token)
        #expect(controller.active == nil)
        #expect(controller.clear(token) == nil)
    }

    @Test("Escape detaches its snapshot before an immediate replacement generation")
    func escapeThenImmediateRestart() throws {
        let coordinator = DictationCoordinator()
        let controller = DictationSessionController()

        let firstStart = coordinator.hotkeyDown(at: 1, profileMode: .clean)
        guard case .startCapture(let firstToken) = firstStart.effects.first else {
            Issue.record("Expected first capture")
            return
        }
        controller.install(session(for: firstToken))

        let escape = coordinator.escapePressed()
        guard case .cancel(let cancelledToken) = escape.effects.first else {
            Issue.record("Expected cancellation")
            return
        }
        let historyID = UUID()
        #expect(controller.update(cancelledToken) {
            $0.cancellationRequested = true
            $0.historyID = historyID
        })
        let cancelledSnapshot = try #require(controller.clear(cancelledToken))

        let secondStart = coordinator.hotkeyDown(at: 2, profileMode: .clean)
        guard case .startCapture(let secondToken) = secondStart.effects.first else {
            Issue.record("Expected immediate replacement capture")
            return
        }
        controller.install(session(for: secondToken))

        #expect(cancelledSnapshot.historyID == historyID)
        #expect(cancelledSnapshot.cancellationRequested)
        #expect(controller.clear(cancelledToken) == nil)
        #expect(controller.active?.token == secondToken)
        #expect(controller.isCurrent(secondToken))
    }

    private func token(generation: UInt64) -> DictationSessionToken {
        DictationSessionToken(generation: generation, id: UUID())
    }

    private func session(for token: DictationSessionToken) -> DictationSession {
        DictationSession(
            token: token,
            startedAt: Date(),
            engine: nil,
            streamingTranscriber: nil,
            asrSelection: .parakeetV2,
            profile: ProfileCatalog.nativeDefaults["default"]!
        )
    }
}
