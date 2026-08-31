import AppKit
import SwiftUI

@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onDeliver: (String) -> Void
    private let onCopy: (String) -> Void
    private let onCancel: () -> Void

    init(
        onDeliver: @escaping (String) -> Void,
        onCopy: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onDeliver = onDeliver
        self.onCopy = onCopy
        self.onCancel = onCancel
        super.init()
    }

    func show(text: String, rawText: String, isRemoteRefiner: Bool) {
        close()
        let view = PreviewEditorView(
            initialText: text,
            rawText: rawText,
            isRemoteRefiner: isRemoteRefiner,
            onDeliver: { [weak self] value in self?.onDeliver(value) },
            onCopy: { [weak self] value in self?.onCopy(value) },
            onCancel: { [weak self] in self?.onCancel() }
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        closingWindow.delegate = nil
        window = nil
        onCancel()
    }
}

private struct PreviewEditorView: View {
    @State private var text: String
    let rawText: String
    let isRemoteRefiner: Bool
    let onDeliver: (String) -> Void
    let onCopy: (String) -> Void
    let onCancel: () -> Void

    init(
        initialText: String,
        rawText: String,
        isRemoteRefiner: Bool,
        onDeliver: @escaping (String) -> Void,
        onCopy: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = State(initialValue: initialText)
        self.rawText = rawText
        self.isRemoteRefiner = isRemoteRefiner
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
