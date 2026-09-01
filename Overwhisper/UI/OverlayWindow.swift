import AppKit
import SwiftUI

// Lets the cancel button respond to the first click even though the
// panel never becomes key (it's a nonactivating overlay).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct OverlayPresentationState: Equatable, Sendable {
    private(set) var visibleToken: DictationSessionToken?
    private(set) var revision: UInt64 = 0

    @discardableResult
    mutating func show(token: DictationSessionToken) -> UInt64 {
        revision &+= 1
        visibleToken = token
        return revision
    }

    mutating func beginHide(token: DictationSessionToken) -> UInt64? {
        guard visibleToken == token else { return nil }
        revision &+= 1
        return revision
    }

    mutating func completeHide(token: DictationSessionToken, revision: UInt64) -> Bool {
        guard visibleToken == token, self.revision == revision else { return false }
        visibleToken = nil
        return true
    }
}

@MainActor
final class OverlayWindow: NSPanel {
    private let appState: AppState
    private var hostingView: NSHostingView<OverlayView>?
    private var presentation = OverlayPresentationState()

    init(appState: AppState, onCancel: @escaping () -> Void) {
        self.appState = appState

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: OverlayMetrics.width, height: OverlayMetrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        // No window shadow — the backdrop fades to transparent at the edges,
        // and a shadow would trace a ghost rectangle around it.
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false

        // Set up the SwiftUI content
        let overlayView = OverlayView(appState: appState, onCancel: onCancel)
        let hostingView = FirstMouseHostingView(rootView: overlayView)
        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
        self.hostingView = hostingView
    }

    func show(position: OverlayPosition, token: DictationSessionToken) {
        presentation.show(token: token)
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
        else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = self.frame.size
        let padding: CGFloat = 20

        var origin: NSPoint

        switch position {
        case .topLeft:
            origin = NSPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.maxY - windowSize.height - padding
            )
        case .topCenter:
            origin = NSPoint(
                x: screenFrame.midX - windowSize.width / 2,
                y: screenFrame.maxY - windowSize.height - padding
            )
        case .topRight:
            origin = NSPoint(
                x: screenFrame.maxX - windowSize.width - padding,
                y: screenFrame.maxY - windowSize.height - padding
            )
        case .bottomLeft:
            origin = NSPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.minY + padding
            )
        case .bottomCenter:
            origin = NSPoint(
                x: screenFrame.midX - windowSize.width / 2,
                y: screenFrame.minY + padding
            )
        case .bottomRight:
            origin = NSPoint(
                x: screenFrame.maxX - windowSize.width - padding,
                y: screenFrame.minY + padding
            )
        }

        self.setFrameOrigin(origin)

        // Animate in
        self.alphaValue = 0
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func showTranscribing() {
        // The view will automatically update based on appState
    }

    func hide(token: DictationSessionToken) {
        guard let revision = presentation.beginHide(token: token) else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.presentation.completeHide(token: token, revision: revision)
                else { return }
                self.orderOut(nil)
            }
        })
    }
}
