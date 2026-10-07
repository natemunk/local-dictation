import Foundation
import AppKit
import Testing
@testable import LocalDictation

@Suite("Overlay presentation tokening")
struct OverlayPresentationTests {
    @Test @MainActor func panelCannotTakeKeyboardFocus() throws {
        _ = NSApplication.shared
        let suite = "OverlayFocus.\(UUID().uuidString)"
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let state = AppState(preferences: prefs)
        let previousKey = NSApp.keyWindow
        let panel = OverlayWindow(appState: state, onCancel: { _ in }, onFinish: { _ in }, onPreview: { _ in }, onSettings: {})
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.contentView?.needsPanelToBecomeKey == false)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(NSApp.keyWindow === previousKey)
        panel.close()
    }

    @Test func dragClampingHandlesMultipleScreenOrigins() {
        let screen = NSRect(x: -1920, y: 100, width: 1920, height: 1080)
        let size = OverlayAppearance.size(compact: false, controls: true)
        let bottom = OverlayGeometry.clamp(NSPoint(x: -3000, y: -100), size: size, to: screen)
        #expect(bottom == NSPoint(x: -1920, y: 100))
        let top = OverlayGeometry.clamp(NSPoint(x: 500, y: 2000), size: size, to: screen)
        #expect(top == NSPoint(x: screen.maxX - size.width, y: screen.maxY - size.height))
        #expect(OverlayAppearance.size(compact: true, controls: false).height < OverlayAppearance.size(compact: false, controls: false).height)
    }
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
