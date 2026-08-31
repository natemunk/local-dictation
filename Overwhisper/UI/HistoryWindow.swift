import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private let viewModel: HistoryViewModel
    private var window: NSWindow?

    init(
        store: HistoryStore,
        onCopy: @escaping (String) -> Void,
        onRepaste: @escaping (String) -> Void,
        onRetryPolish: @escaping (HistoryEntry) -> Void
    ) {
        viewModel = HistoryViewModel(
            store: store,
            onCopy: onCopy,
            onRepaste: onRepaste,
            onRetryPolish: onRetryPolish
        )
    }

    func show() {
        viewModel.reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Dictation History"
        window.minSize = NSSize(width: 720, height: 430)
        window.contentView = NSHostingView(rootView: HistoryView(viewModel: viewModel))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func refresh() {
        viewModel.reload()
    }
}

@MainActor
private final class HistoryViewModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var selection: UUID?
    @Published var query = ""
    @Published var errorMessage: String?

    let store: HistoryStore
    let onCopy: (String) -> Void
    let onRepaste: (String) -> Void
    let onRetryPolish: (HistoryEntry) -> Void

    init(
        store: HistoryStore,
        onCopy: @escaping (String) -> Void,
        onRepaste: @escaping (String) -> Void,
        onRetryPolish: @escaping (HistoryEntry) -> Void
    ) {
        self.store = store
        self.onCopy = onCopy
        self.onRepaste = onRepaste
        self.onRetryPolish = onRetryPolish
    }

    var selectedEntry: HistoryEntry? {
        entries.first { $0.id == selection }
    }

    func reload() {
        do {
            entries = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try store.fetchRecent(limit: 500)
                : try store.search(query, limit: 500)
            if !entries.contains(where: { $0.id == selection }) {
                selection = entries.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        guard let selection else { return }
        do {
            _ = try store.delete(id: selection)
            self.selection = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAll() {
        do {
            _ = try store.deleteAll()
            selection = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var showingDeleteAll = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search raw and polished text", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                    .onSubmit { viewModel.reload() }
                    .onChange(of: viewModel.query) { _, _ in viewModel.reload() }

                List(viewModel.entries, selection: $viewModel.selection) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.preview(entry.deliveredText))
                            .lineLimit(2)
                        HStack {
                            Text(entry.timestamp, style: .relative)
                            Text(entry.destinationDisplayName ?? "Unknown app")
                            Spacer()
                            Text(entry.deliveryStatus.rawValue.replacingOccurrences(of: "_", with: " "))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                    .padding(.vertical, 3)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 330)
        } detail: {
            if let entry = viewModel.selectedEntry {
                entryDetail(entry)
            } else {
                ContentUnavailableView("No Dictation Selected", systemImage: "waveform")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Delete Entry", systemImage: "trash", action: viewModel.deleteSelected)
                    .disabled(viewModel.selectedEntry == nil)
                Button("Delete All", systemImage: "trash.slash") { showingDeleteAll = true }
                    .disabled(viewModel.entries.isEmpty)
            }
        }
        .alert("Delete all dictation history?", isPresented: $showingDeleteAll) {
            Button("Delete All", role: .destructive, action: viewModel.deleteAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all raw and polished transcripts. Audio is not stored here.")
        }
        .alert(
            "History Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown history error")
        }
    }

    private func entryDetail(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.headline)
                    Text("\(entry.destinationDisplayName ?? "Unknown app") · \(entry.mode.rawValue.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { viewModel.onCopy(entry.deliveredText) }
                Button("Repaste Here") { viewModel.onRepaste(entry.deliveredText) }
                    .buttonStyle(.borderedProminent)
            }

            if entry.refinementStatus == .failed {
                HStack {
                    Label("Polish failed; deterministic text was retained", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry Polish") { viewModel.onRetryPolish(entry) }
                }
            }

            HSplitView {
                transcriptPane(title: "Raw", text: entry.rawText)
                transcriptPane(title: "Polished / delivered", text: entry.polishedText ?? entry.rawText)
            }

            HStack(spacing: 16) {
                metric("ASR", entry.asrLatency)
                metric("Refinement", entry.refinementLatency)
                metric("Total", entry.totalLatency)
                if !entry.unrecognizedCommandCandidates.isEmpty {
                    Text("Unrecognized: \(entry.unrecognizedCommandCandidates.joined(separator: ", "))")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func transcriptPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(minWidth: 220)
    }

    private func metric(_ title: String, _ value: TimeInterval?) -> some View {
        Text("\(title): \(value.map { String(format: "%.2fs", $0) } ?? "—")")
    }

    private static func preview(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count > 100 ? "\(collapsed.prefix(97))…" : collapsed
    }
}
