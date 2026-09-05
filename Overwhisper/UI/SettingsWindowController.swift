import AppKit

/// Owns the Settings window only while it is open.
///
/// Keeping a closed `NSWindow` and its `NSHostingView` alive also keeps SwiftUI
/// subscriptions alive. Settings previously retained a permission timer after
/// close, which caused hidden layout work on the main thread. A fresh content
/// hierarchy is intentionally created on every reopen.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    typealias ContentViewFactory = @MainActor () -> NSView
    typealias WindowPresenter = @MainActor (NSWindow) -> Void

    private let makeContentView: ContentViewFactory
    private let presentWindow: WindowPresenter
    private(set) var window: NSWindow?

    init(
        makeContentView: @escaping ContentViewFactory,
        presentWindow: @escaping WindowPresenter = { window in
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.makeContentView = makeContentView
        self.presentWindow = presentWindow
        super.init()
    }

    func show() {
        if let window {
            presentWindow(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 646, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Dictation Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView()
        window.center()
        self.window = window
        presentWindow(window)
    }

    func close() {
        guard let window else { return }
        release(window)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        release(closingWindow)
    }

    private func release(_ closingWindow: NSWindow) {
        closingWindow.delegate = nil
        closingWindow.contentView?.removeFromSuperview()
        closingWindow.contentViewController = nil
        closingWindow.contentView = nil
        if closingWindow === window {
            window = nil
        }
    }
}
