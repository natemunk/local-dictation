import Foundation
import Combine
import os

@MainActor
final class ClipboardRewriteModel: ObservableObject {
    @Published private(set) var session = RewriteSession(kind: .clipboard, original: "")
    @Published var source = ""
    @Published var instructions = ""
    @Published var canReplaceSelection = false
    @Published var canInsertAfterSelection = false
    @Published var isDelivering = false
    @Published var dictationCanPaste = false
    var acceptTitle: String {
        if isReply { return "Copy & Close" }
        if canReplaceSelection { return "Replace selection" }
        return dictationCanPaste ? "Paste & Close" : "Copy & Close"
    }
    @Published var action: WritingAction = .clean
    @Published var result = "" {
        didSet {
            if message == "Original text — no rewrite applied.", result != session.original {
                message = "Edited original — no AI rewrite applied."
            }
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isComplete = false
    var isOriginal: Bool { isComplete && result == session.original }
    @Published private(set) var message: String?
    @Published var showingResult = false
    private(set) var hasDraft = false
    private let writer: any ClipboardWriting
    private let isDictationBusy: () -> Bool
    private let copy: (String) -> Bool
    private let deadline: Duration
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generationStarted: ContinuousClock.Instant?
    private var receivedFirstOutput = false
    // A canceled provider must drain before another model request starts.
    private var providerActive = false
    private var retainedResult: String?
    private var retainedGenerated = false
    private var retainedVersionIndex = -1
    /// Includes canceled inference that has not yet drained.
    var blocksRemoteInference: Bool { providerActive || isRunning }
    var hasContentToDiscard: Bool {
        !source.isEmpty || !instructions.isEmpty || !result.isEmpty || !session.versions.isEmpty
    }
    private(set) var usedLocalModel = false
    var isDictationSource: Bool { session.kind == .dictation }
    var sourceLabel: String { session.label }
    var isReply: Bool { session.isReply || action == .reply }
    var canGoPrevious: Bool { session.versionIndex > 0 }
    var canGoNext: Bool { session.versionIndex + 1 < session.versions.count }
    private static let logger = Logger(subsystem: AppLogger.subsystem, category: "clipboard_rewrite")

    init(writer: any ClipboardWriting = AppleClipboardWriter(), deadline: Duration = .seconds(45),
         isDictationBusy: @escaping () -> Bool, copy: @escaping (String) -> Bool) {
        self.writer = writer
        self.deadline = deadline
        self.isDictationBusy = isDictationBusy
        self.copy = copy
    }

    func loadClipboard(_ text: String?) { loadSource(text, kind: .clipboard) }

    func loadSource(_ text: String?, kind: RewriteSession.SourceKind) {
        cancel()
        session = RewriteSession(kind: kind, original: text ?? "")
        dictationCanPaste = kind == .dictation
        retainedResult = nil
        retainedVersionIndex = -1
        retainedGenerated = false
        usedLocalModel = false
        canReplaceSelection = false
        canInsertAfterSelection = false
        source = text ?? ""
        instructions = ""
        action = .clean
        result = ""
        showingResult = false
        isComplete = false

        hasDraft = true
        message = writer.availabilityMessage()
        if message == nil, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = WritingFailure.emptySource.message
        }
    }

    func resolveOriginal(_ text: String) {
        source = text
        session.original = text
    }

    func prepareRevision() -> Bool {
        guard isComplete, !isRunning, !isDelivering, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        session.remember(result, generated: usedLocalModel)
        retainedResult = result
        retainedGenerated = usedLocalModel
        retainedVersionIndex = session.versionIndex
        source = result
        instructions = ""
        action = session.isReply ? .reply : .custom
        showingResult = false
        return true
    }

    func restoreDraft() {
        // A completed result may have newer manual edits than the retained snapshot.
        if isComplete { showingResult = true; return }
        guard let retainedResult else { return }
        result = retainedResult
        usedLocalModel = retainedGenerated
        session.versionIndex = retainedVersionIndex
        isComplete = true
        showingResult = true
    }

    func recoverForResume() {
        cancel()
        restoreDraft()
        // First-generation cancellation has no completed draft: reopen the source/options.
        if !isComplete { showingResult = false }
    }

    func moveVersion(_ offset: Int) {
        guard !isRunning else { return }
        // Preserve manual edits before navigating away, without discarding forward history.
        if isComplete, session.versionIndex == -1, result != session.original, offset == 1 {
            // Save an edited Original as a draft, while returning to the draft last viewed.
            let target = session.versions.indices.contains(session.originalReturnIndex)
                ? session.originalReturnIndex : session.versions.count - 1
            let count = session.versions.count
            session.remember(result, generated: usedLocalModel)
            let removed = max(0, count + 1 - session.versions.count)
            session.originalReturnIndex = max(0, target - removed)
            session.versionIndex = -1
        } else if isComplete, session.versions.indices.contains(session.versionIndex) {
            session.versions[session.versionIndex] = result
            session.generatedVersions[session.versionIndex] = usedLocalModel
        }
        guard let text = session.move(offset) else { return }
        message = nil
        result = text
        usedLocalModel = session.generatedVersions[session.versionIndex]
        isComplete = true

        showingResult = true
    }

    var availabilityMessage: String? { writer.availabilityMessage() }

    func reviewOriginal() {
        guard !isDelivering else { return }
        cancel()
        if session.original.isEmpty { session.original = source }
        guard !session.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isComplete {
            if session.versions.indices.contains(session.versionIndex) {
                session.versions[session.versionIndex] = result
                session.generatedVersions[session.versionIndex] = usedLocalModel
            } else if result != session.original { session.remember(result, generated: usedLocalModel) }
        }
        if session.versionIndex >= 0 { session.originalReturnIndex = session.versionIndex }
        result = session.original
        usedLocalModel = false
        session.versionIndex = -1

        isComplete = true
        showingResult = true
        message = "Original text — no rewrite applied."
    }

    func setNotice(_ message: String?) { self.message = message }

    func moveSelection(_ offset: Int) {
        let actions = WritingAction.allCases
        let index = actions.firstIndex(of: action) ?? 0
        action = actions[min(max(0, index + offset), actions.count - 1)]
    }

    func start() {
        guard !isRunning, !isDelivering else { return }
        guard !providerActive else {
            message = "The previous rewrite is stopping. Try again in a moment."
            return
        }
        guard !isDictationBusy() else {
            message = "Finish dictation first, then try Rewrite again."
            return
        }
        if let unavailable = writer.availabilityMessage() { message = unavailable; return }
        let request = WritingRequest(source: source, action: action, instructions: instructions, original: session.original, continuingReply: session.isReply)
        do { try request.validate() }
        catch { message = (error as? WritingFailure)?.message ?? WritingFailure.failed.message; return }
        if session.original.isEmpty { session.original = source }
        if isComplete { session.remember(result, generated: usedLocalModel); retainedResult = result; retainedGenerated = usedLocalModel; retainedVersionIndex = session.versionIndex }
        if action == .reply { session.isReply = true }
        let id = UUID()
        generation = id
        isRunning = true
        providerActive = true

        isComplete = false
        showingResult = true
        result = ""
        message = nil
        let start = ContinuousClock.now
        generationStarted = start
        receivedFirstOutput = false
        let actionID = request.action.rawValue
        Self.logger.info("Rewrite started action=\(actionID, privacy: .public)")
        timeoutTask = Task { [weak self, deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, self.generation == id, self.isRunning else { return }
            self.cancel(message: "The rewrite took too long. Your source is still here; try a shorter selection.")
        }
        task = Task { [weak self, writer] in
            defer { self?.providerActive = false; self?.task = nil }
            do {
                let final = try await writer.rewrite(request) { [weak self] partial in
                    await self?.receive(partial, generation: id)
                }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.timeoutTask?.cancel()
                self.result = final
                self.isRunning = false
                self.isComplete = true
                self.session.remember(final, generated: true)
                self.usedLocalModel = true
                self.retainedGenerated = true
                self.retainedResult = final
                self.retainedVersionIndex = self.session.versionIndex
                let duration = start.duration(to: .now).components
                let milliseconds = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
                Self.logger.info("Rewrite completed action=\(actionID, privacy: .public) milliseconds=\(milliseconds)")
            } catch {
                guard let self, self.generation == id else { return }
                self.timeoutTask?.cancel()
                self.isRunning = false
                self.isComplete = false
                self.restoreDraft()
                self.message = (error as? WritingFailure)?.message ?? WritingFailure.failed.message
                // Never log model errors, source, instructions, or output.
                Self.logger.notice("Rewrite failed action=\(actionID, privacy: .public)")
            }
        }
    }

    private func receive(_ partial: String, generation: UUID) {
        guard self.generation == generation, isRunning else { return }
        if !receivedFirstOutput, let start = generationStarted {
            receivedFirstOutput = true
            let elapsed = start.duration(to: .now).components
            let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            Self.logger.info("Rewrite first output milliseconds=\(ms)")
        }
        result = partial
    }

    func cancel(message: String? = nil) {
        let wasRunning = isRunning
        generation = UUID()
        task?.cancel()
        timeoutTask?.cancel()
        if isRunning {
            isComplete = false
            self.message = message ?? "Rewrite canceled. Partial text is incomplete; your source is still here."
            Self.logger.info("Rewrite canceled")
        }
        isRunning = false
        if wasRunning {
            restoreDraft()
            if isComplete, message == nil { self.message = "Rewrite canceled. Your previous completed draft is restored." }
        }
    }

    func interruptForDictation() {
        cancel(message: "Rewrite canceled to give dictation priority. Your draft is still here; retry when dictation finishes.")
    }

    func copyResult() -> Bool {
        guard isComplete, !isRunning, !isDelivering, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard copy(result) else {
            message = PreviewNotice.copyFailureMessage
            return false
        }
        message = nil
        return true
    }
}
