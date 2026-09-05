import AppKit
import Testing
@testable import LocalDictation

@Suite("Settings performance", .serialized)
struct SettingsPerformanceTests {
    @Test("closing Settings detaches and forgets its SwiftUI content hierarchy")
    @MainActor
    func closeReleasesContent() throws {
        var lastContentView: NSView?
        var creationCount = 0
        let controller = SettingsWindowController(
            makeContentView: {
                creationCount += 1
                let content = NSView()
                lastContentView = content
                return content
            },
            presentWindow: { _ in }
        )

        controller.show()
        let firstWindow = try #require(controller.window)
        #expect(creationCount == 1)
        #expect(lastContentView != nil)

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: firstWindow)
        )
        #expect(controller.window == nil)
        #expect(lastContentView?.superview == nil)
        #expect(firstWindow.contentView !== lastContentView)

        controller.show()
        #expect(creationCount == 2)
        #expect(controller.window != nil)
        #expect(lastContentView != nil)

        let secondWindow = try #require(controller.window)
        let secondContentView = try #require(lastContentView)
        controller.close()
        #expect(controller.window == nil)
        #expect(secondContentView.superview == nil)
        #expect(secondWindow.contentView !== secondContentView)
    }
}
