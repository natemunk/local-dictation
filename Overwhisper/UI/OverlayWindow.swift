import AppKit
import SwiftUI
import Combine

// Lets the cancel button respond to the first click even though the
// panel never becomes key (it's a nonactivating overlay).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

/// Only the header owns native window dragging; controls remain clickable.
struct OverlayDragRegion: NSViewRepresentable {
    let onDragEnd: () -> Void
    func makeNSView(context: Context) -> NSView { OverlayDragHandle(onDragEnd: onDragEnd) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? OverlayDragHandle)?.onDragEnd = onDragEnd
    }
}

private final class OverlayDragHandle: NSView {
    var onDragEnd: () -> Void
    init(onDragEnd: @escaping () -> Void) { self.onDragEnd = onDragEnd; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onDragEnd()
    }
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
    private var draggedInSession = false
    private var appearanceObservers = Set<AnyCancellable>()
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(appState: AppState, onCancel: @escaping (DictationSessionToken) -> Void,
         onFinish: @escaping (DictationSessionToken) -> Void,
         onPreview: @escaping (DictationSessionToken) -> Void,
         onSettings: @escaping () -> Void) {
        self.appState = appState

        super.init(
            contentRect: NSRect(origin: .zero, size: OverlayAppearance.size(compact: appState.overlayCompact, controls: false)),
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
        self.becomesKeyOnlyIfNeeded = true

        // Set up the SwiftUI content
        let overlayView = OverlayView(appState: appState,
            onCancel: { [weak self] in if let token = self?.presentation.visibleToken { onCancel(token) } },
            onFinish: { [weak self] in if let token = self?.presentation.visibleToken { onFinish(token) } },
            onPreview: { [weak self] in if let token = self?.presentation.visibleToken { onPreview(token) } },
            onSettings: onSettings,
            onDragEnd: { [weak self] in self?.draggedInSession = true; self?.clampToScreen() },
            onPosition: { [weak self] position in
                self?.draggedInSession = false
                appState.overlayPosition = position
                self?.refreshAppearance()
            })
        let hostingView = FirstMouseHostingView(rootView: overlayView)
        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
        self.hostingView = hostingView
        appState.$overlayCompact.combineLatest(appState.$overlayQuickControlsVisible)
            .dropFirst().sink { [weak self] _ in
                Task { @MainActor in self?.refreshAppearance() }
            }.store(in: &appearanceObservers)
        appState.$overlayPosition.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.draggedInSession = false
                self?.refreshAppearance()
            }
        }.store(in: &appearanceObservers)
    }

    func show(position: OverlayPosition, token: DictationSessionToken) {
        let sameSession = presentation.visibleToken == token
        let wasVisible = isVisible
        if !sameSession {
            draggedInSession = false
            appState.overlayQuickControlsVisible = false
        }
        presentation.show(token: token)
        refreshAppearance(position: position, preserveOrigin: sameSession && wasVisible)
        if wasVisible {
            // Re-show during pasting or a pending hide must not fade to zero.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.animator().alphaValue = 1
            }
            orderFrontRegardless()
            return
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    private func refreshAppearance(position: OverlayPosition? = nil, preserveOrigin: Bool = false) {
        let size = OverlayAppearance.size(compact: appState.overlayCompact, controls: appState.overlayQuickControlsVisible)
        let old = frame
        setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
        if draggedInSession || preserveOrigin { clampToScreen(); return }
        positionAtPreset(position ?? appState.overlayPosition)
    }

    private func clampToScreen() {
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return }
        setFrameOrigin(OverlayGeometry.clamp(frame.origin, size: frame.size, to: screen.visibleFrame))
    }

    private func positionAtPreset(_ position: OverlayPosition) {
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

    }

    func showTranscribing() {
        // The view will automatically update based on appState
    }

    func hide(token: DictationSessionToken) {
        guard let revision = presentation.beginHide(token: token) else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
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
