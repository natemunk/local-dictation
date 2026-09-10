import AppKit
import SwiftUI

@MainActor
final class PreviewNotice: ObservableObject {
    static let copyFailureMessage = "Could not copy. Your text is still here; try Copy again or select and copy it manually."
    @Published var message: String?
}

@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var token: DictationSessionToken?
    private(set) var notice = PreviewNotice()
    private let presentWindow: @MainActor (NSWindow) -> Void
    private let onDeliver: (DictationSessionToken, String) -> Void
    private let onCopy: (DictationSessionToken, String) -> Void
    private let onCancel: (DictationSessionToken) -> Void

    init(
        onDeliver: @escaping (DictationSessionToken, String) -> Void,
        onCopy: @escaping (DictationSessionToken, String) -> Void,
        onCancel: @escaping (DictationSessionToken) -> Void,
        presentWindow: @escaping @MainActor (NSWindow) -> Void = {
            $0.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.presentWindow = presentWindow
        self.onDeliver = onDeliver
        self.onCopy = onCopy
        self.onCancel = onCancel
        super.init()
    }

    func show(
        text: String,
        rawText: String,
        isRemoteRefiner: Bool,
        token: DictationSessionToken
    ) {
        close()
        self.token = token
        notice.message = nil
        let view = PreviewEditorView(
            initialText: text,
            rawText: rawText,
            isRemoteRefiner: isRemoteRefiner,
            notice: notice,
            onDeliver: { [weak self] value in self?.onDeliver(token, value) },
            onCopy: { [weak self] value in self?.onCopy(token, value) },
            onCancel: { [weak self] in self?.onCancel(token) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Dictation Preview"
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        presentWindow(window)
    }

    func attemptCopy(_ text: String, token: DictationSessionToken, using copy: (String) -> Bool) -> Bool {
        guard self.token == token else { return false }
        guard copy(text) else {
            showNotice(PreviewNotice.copyFailureMessage, token: token)
            return false
        }
        notice.message = nil
        return true
    }

    func showNotice(_ message: String, token: DictationSessionToken) {
        guard self.token == token else { return }
        notice.message = message
    }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        token = nil
    }

    func close(token: DictationSessionToken) {
        guard self.token == token else { return }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        let closingToken = token
        closingWindow.delegate = nil
        window = nil
        token = nil
        if let closingToken { onCancel(closingToken) }
    }
}

private struct PreviewEditorView: View {
    @State private var text: String
    let rawText: String
    let isRemoteRefiner: Bool
    @ObservedObject var notice: PreviewNotice
    let onDeliver: (String) -> Void
    let onCopy: (String) -> Void
    let onCancel: () -> Void

    init(
        initialText: String,
        rawText: String,
        isRemoteRefiner: Bool,
        notice: PreviewNotice,
        onDeliver: @escaping (String) -> Void,
        onCopy: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = State(initialValue: initialText)
        self.rawText = rawText
        self.isRemoteRefiner = isRemoteRefiner
        self.notice = notice
        self.onDeliver = onDeliver
        self.onCopy = onCopy
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.title2.weight(.semibold))
                if isRemoteRefiner {
                    Text("REMOTE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: Capsule())
                        .accessibilityLabel("Remote text refiner active")
                }
                Spacer()
                Text("The original field will be revalidated before paste")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = notice.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            if rawText != text {
                DisclosureGroup("Raw transcript") {
                    Text(rawText)
                        .textSelection(.enabled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy") { onCopy(text) }
                Button("Paste") { onDeliver(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
    }
}
