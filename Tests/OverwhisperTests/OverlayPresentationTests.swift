import Foundation
import Testing
@testable import LocalDictation

@Suite("Overlay presentation tokening")
struct OverlayPresentationTests {
    @Test("a stale hide completion cannot hide a replacement session")
    func staleHideCannotHideReplacement() {
        let first = DictationSessionToken(generation: 1, id: UUID())
        let second = DictationSessionToken(generation: 2, id: UUID())
        var state = OverlayPresentationState()

        state.show(token: first)
        let firstHideRevision = state.beginHide(token: first)
        #expect(firstHideRevision != nil)

        state.show(token: second)
        let staleHideCompleted = state.completeHide(
            token: first,
            revision: firstHideRevision!
        )
        #expect(!staleHideCompleted)
        #expect(state.visibleToken == second)
    }

    @Test("only the current token can begin and complete a hide")
    func currentTokenOwnsHide() {
        let token = DictationSessionToken(generation: 1, id: UUID())
        let stale = DictationSessionToken(generation: 0, id: UUID())
        var state = OverlayPresentationState()

        state.show(token: token)
        #expect(state.beginHide(token: stale) == nil)
        let revision = state.beginHide(token: token)
        #expect(revision != nil)
        let currentHideCompleted = state.completeHide(
            token: token,
            revision: revision!
        )
        #expect(currentHideCompleted)
        #expect(state.visibleToken == nil)
    }
}
