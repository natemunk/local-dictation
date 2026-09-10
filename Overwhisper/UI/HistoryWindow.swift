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
        onAddVocabularyCorrection: @escaping (HistoryEntry) -> Void
    ) {
        viewModel = HistoryViewModel(
            store: store,
            onCopy: onCopy,
            onRepaste: onRepaste,
            onAddVocabularyCorrection: onAddVocabularyCorrection
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
final class HistoryViewModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var selection: UUID?
    @Published var query = ""
    @Published var errorMessage: String?
    @Published var editDraft = ""
    @Published var isEditing = false
    @Published private(set) var conflictingText: String?

    let store: HistoryStore
    let onCopy: (String) -> Void
    let onRepaste: (String) -> Void
    let onAddVocabularyCorrection: (HistoryEntry) -> Void
    private var editID: UUID?
    private var editBaseRevision: Int64?
    @Published private(set) var isSavingEdit = false
    private var saveID: UUID?
    private let writeEdit: (UUID, String?, Int64) async throws -> HistoryEntry
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    init(
        store: HistoryStore,
        onCopy: @escaping (String) -> Void,
        onRepaste: @escaping (String) -> Void,
        onAddVocabularyCorrection: @escaping (HistoryEntry) -> Void,
        writeEdit: ((UUID, String?, Int64) async throws -> HistoryEntry)? = nil
    ) {
        self.writeEdit = writeEdit ?? { id, text, revision in
            try await store.setUserEditedText(id: id, text: text, baseRevision: revision)
        }
        self.store = store
        self.onCopy = onCopy
        self.onRepaste = onRepaste
        self.onAddVocabularyCorrection = onAddVocabularyCorrection
    }

    func beginEditing() {
        guard let entry = selectedEntry else { return }
        conflictingText = nil
        editDraft = entry.userEditedText ?? entry.displayText
        editBaseRevision = entry.entryRevision
        editID = UUID()
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        conflictingText = nil
        editDraft = ""
        editBaseRevision = nil
        editID = nil
    }

    func saveEdit() {
        guard let selection, let editID, let revision = editBaseRevision else { return }
        persistEdit(id: selection, text: editDraft, revision: revision, editID: editID)
    }

    func revertEdit() {
        guard let entry = selectedEntry else { return }
        persistEdit(id: entry.id, text: nil, revision: entry.entryRevision, editID: editID)
    }

    private func persistEdit(id: UUID, text: String?, revision: Int64, editID: UUID?) {
        guard !isSavingEdit else { return }
        let operation = UUID()
        saveID = operation
        isSavingEdit = true
        Task { @MainActor [weak self, writeEdit] in
            do {
                let updated = try await writeEdit(id, text, revision)
                guard let self else { return }
                if let index = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[index] = updated
                }
                if self.selection == id, self.editID == editID {
                    if text == nil || self.editDraft == text {
                        self.cancelEditing()
                    } else {
                        // Typing may continue while this write is suspended.
                        // Keep those newer words and base their next save on
                        // the revision returned by our successful write.
                        self.editBaseRevision = updated.entryRevision
                    }
                }
            } catch {
                guard let self else { return }
                if self.selection == id, self.editID == editID {
                    // Keep this draft and its original revision. A retry must
                    // never silently overwrite the other device's version.
                    if let storeError = error as? HistoryStoreError,
                       case .revisionConflict = storeError {
                        self.errorMessage = "This entry changed on another device. Your draft is still open; copy it before cancelling and reopening the latest entry."
                        if let latest = try? await self.store.fetch(id: id),
                           let index = self.entries.firstIndex(where: { $0.id == id }) {
                            self.entries[index] = latest
                            if self.selection == id, self.editID == editID {
                                self.conflictingText = latest.displayText
                            }
                        }
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
            guard let self, self.saveID == operation else { return }
            self.saveID = nil
            self.isSavingEdit = false
        }
    }

    func togglePin(_ entry: HistoryEntry) {
        let pinned = !entry.isPinned
        Task { @MainActor [weak self, store] in
            do {
                _ = try await store.setPinned(id: entry.id, pinned, baseRevision: entry.entryRevision)
                self?.reload()
            } catch {
                self?.handle(error)
            }
        }
    }

    /// A concurrent Mac or device change is recoverable: reload and let the
    /// user retry rather than reporting a revision number they never saw.
    private func handle(_ error: Error) {
        if let storeError = error as? HistoryStoreError,
           case .revisionConflict = storeError {
            errorMessage = "This entry changed; please try again."
            reload()
            return
        }
        errorMessage = error.localizedDescription
    }

    var selectedTextForDelivery: String {
        isEditing ? editDraft : selectedEntry?.displayText ?? ""
    }

    var selectedEntry: HistoryEntry? {
        entries.first { $0.id == selection }
    }

    func reload() {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self, store] in
            do {
                let loaded: [HistoryEntry]
                if requestedQuery.isEmpty {
                    loaded = try await store.fetchRecent(limit: 500)
                } else {
                    loaded = try await store.search(requestedQuery, limit: 500)
                }
                guard !Task.isCancelled,
                      let self,
                      self.loadGeneration == generation
                else { return }
                self.entries = loaded
                if !loaded.contains(where: { $0.id == self.selection }) {
                    self.selection = loaded.first?.id
                }
                self.errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSelected() {
        guard let selection else { return }
        Task { @MainActor [weak self, store] in
            do {
                _ = try await store.delete(id: selection)
                guard let self else { return }
                self.selection = nil
                self.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func deleteTranscriptHistory() {
        Task { @MainActor [weak self, store] in
            do {
                _ = try await store.deleteTranscriptHistory()
                guard let self else { return }
                self.selection = nil
                self.reload()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var showingDeleteAll = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search raw, polished, and edited text", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                    .onSubmit { viewModel.reload() }
                    .onChange(of: viewModel.query) { _, _ in viewModel.reload() }

                List(viewModel.entries, selection: $viewModel.selection) { entry in
                    row(entry)
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
        .onChange(of: viewModel.selection) { _, _ in viewModel.cancelEditing() }
        .toolbar {
            ToolbarItemGroup {
                Button("Delete Entry", systemImage: "trash", action: viewModel.deleteSelected)
                    .disabled(viewModel.selectedEntry == nil)
                Button("Delete Transcript History", systemImage: "trash.slash") {
                    showingDeleteAll = true
                }
                    .disabled(viewModel.entries.isEmpty)
            }
        }
        .alert("Delete all transcript history?", isPresented: $showingDeleteAll) {
            Button(
                "Delete Transcript History",
                role: .destructive,
                action: viewModel.deleteTranscriptHistory
            )
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all raw and polished transcripts. Transcript-free analytics are retained; reset them separately in Settings → Privacy.")
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

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                }
                Text(Self.preview(entry.displayText))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(entry.timestamp, style: .relative)
                Text(Self.sourceLabel(entry.sourceKind))
                if let route = Self.routeLabel(entry.remoteRoute) {
                    Text(route)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if entry.sourceKind == .desktop {
                    Text(entry.destinationDisplayName ?? "Unknown app")
                        .lineLimit(1)
                }
                Spacer()
                Text(Self.statusLabel(entry.deliveryStatus))
            }
            .font(.caption2)
            .foregroundStyle(Color.secondary)
        }
    }

    private static func statusLabel(_ status: HistoryDeliveryStatus) -> String {
        status.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func entryDetail(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.headline)
                    Text(Self.detailSubtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.userEditedText != nil {
                        Text("Edited by you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Copy") { viewModel.onCopy(viewModel.selectedTextForDelivery) }
                Button("Paste Again") { viewModel.onRepaste(viewModel.selectedTextForDelivery) }
                    .buttonStyle(.borderedProminent)
                Button("Add Vocabulary Correction…") {
                    viewModel.onAddVocabularyCorrection(entry)
                }
            }

            HStack(spacing: 10) {
                Button(entry.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                    viewModel.togglePin(entry)
                }
                Text("Pinned entries are kept until you unpin or delete them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.isEditing {
                    Button("Cancel", action: viewModel.cancelEditing)
                    Button("Save", action: viewModel.saveEdit)
                        .disabled(viewModel.isSavingEdit)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Edit", systemImage: "pencil", action: viewModel.beginEditing)
                    if entry.userEditedText != nil {
                        Button("Revert to Original", action: viewModel.revertEdit)
                            .disabled(viewModel.isSavingEdit)
                    }
                }
            }

            if entry.refinementStatus == .failed {
                Label("Model cleanup failed; deterministic text was retained", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if viewModel.isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your edit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.editDraft)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(4)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    if let conflictingText = viewModel.conflictingText {
                        DisclosureGroup("Latest saved text from the other device") {
                            Text(conflictingText)
                                .textSelection(.enabled)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Saving keeps the raw and polished transcripts unchanged. Clearing the field restores the original text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HSplitView {
                    transcriptPane(title: "Raw", text: entry.rawText)
                    transcriptPane(title: "Polished / delivered", text: entry.deliveredText)
                    if let edited = entry.userEditedText {
                        transcriptPane(title: "Edited", text: edited)
                    }
                }
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

    private static func detailSubtitle(_ entry: HistoryEntry) -> String {
        var parts = [sourceLabel(entry.sourceKind)]
        if let route = routeLabel(entry.remoteRoute) {
            parts.append(route)
        }
        if entry.sourceKind == .desktop {
            parts.append(entry.destinationDisplayName ?? "Unknown app")
        }
        parts.append(entry.mode.rawValue.capitalized)
        return parts.joined(separator: " · ")
    }

    private static func sourceLabel(_ kind: HistorySourceKind) -> String {
        switch kind {
        case .desktop: "Desktop"
        case .iphoneShortcut: "Shortcut"
        case .iphonePWA: "PWA"
        }
    }

    private static func routeLabel(_ route: String?) -> String? {
        switch route {
        case "mac_local": "Mac"
        case "cloud_fallback": "Cloud"
        default: nil
        }
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
