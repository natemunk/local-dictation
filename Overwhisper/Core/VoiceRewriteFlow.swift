import Foundation
import Combine
import os

/// Coordinates two independent inputs without queuing model inference: capture
/// instructions immediately, then transcribe only after the source ASR finishes.
@MainActor
final class VoiceRewriteFlow: ObservableObject {
    enum Stage: Equatable { case inactive, listening, transcribing, ready }
    @Published private(set) var stage: Stage = .inactive
    @Published var expanded = false
    @Published private(set) var sourcePending = false
    @Published private(set) var level: Float = 0
    @Published private(set) var notice: String?
    var isDictationSource: Bool { model.isDictationSource }
    @Published private(set) var isRevision = false
    var operationID: UUID { generation }
    var isActive: Bool { stage != .inactive }
    var isBusy: Bool { sourcePending || stage == .listening || stage == .transcribing }
    let model: ClipboardRewriteModel
    private let recorder: any RewriteInstructionRecording
    private let transcribe: (URL) async throws -> String
    private let deleteAudio: (URL) -> Void
    private let transcriptionLimit: Duration
    private let limit: Duration
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var audioURL: URL?
    private var autoRewrite = false
    private var stoppedAt: ContinuousClock.Instant?
    private static let logger = Logger(subsystem: AppLogger.subsystem, category: "rewrite_instructions")

    init(model: ClipboardRewriteModel, recorder: any RewriteInstructionRecording,
         limit: Duration = .seconds(60), transcriptionLimit: Duration = .seconds(45),
         deleteAudio: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) },
         transcribe: @escaping (URL) async throws -> String) {
        self.model = model
        self.recorder = recorder
        self.limit = limit
        self.transcriptionLimit = transcriptionLimit
        self.deleteAudio = deleteAudio
        self.transcribe = transcribe
    }

    func begin(source: String?, dictation: Bool, listen: Bool = true, kind: RewriteSession.SourceKind? = nil, preservingSession: Bool = false) {
        cancel()
        let id = UUID()
        generation = id
        isRevision = preservingSession
        sourcePending = dictation && !preservingSession
        if !preservingSession {
            model.loadSource(source, kind: kind ?? (dictation ? .dictation : .clipboard))
            model.action = .custom
        }
        model.setNotice(nil)
        notice = nil
        expanded = false
        stage = .listening
        if let unavailable = model.availabilityMessage {
            stage = .ready; expanded = true; notice = unavailable
            return
        }
        if !dictation, model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stage = .ready; expanded = true; notice = "Copy some text first, or type it under Source text."
            return
        }
        if !listen {
            stage = .ready; expanded = true; model.action = .clean
            return
        }
        do {
            try recorder.start(onPartial: { [weak self] text in
                guard let self, self.generation == id, self.stage == .listening else { return }
                self.model.instructions = text
            }, onLevel: { [weak self] level in
                guard let self, self.generation == id, self.stage == .listening else { return }
                self.level = level
            }, onFailure: { [weak self] in
                guard let self, self.generation == id else { return }
                self.fail("Instruction recording stopped. Your source is safe; type your instructions below.")
            })
            limitTask = Task { [weak self, limit] in
                do { try await Task.sleep(for: limit) } catch { return }
                guard let self, self.generation == id, self.stage == .listening else { return }
                self.notice = "Instruction recording reached one minute. Review the instructions before rewriting."
                self.expand()
            }
        } catch {
            fail("Could not start instruction recording. Check microphone permission or type your instructions below.")
        }
    }

    func beginRevision() {
        guard model.prepareRevision() else { return }
        begin(source: model.source, dictation: isDictationSource, preservingSession: true)
    }

    func cancelOperation() {
        cancel()
        model.restoreDraft()
        stage = .ready
        expanded = !model.showingResult
    }

    func resume() {
        stage = .ready
        expanded = true
    }

    func resolveSource(_ text: String) {
        guard isActive, sourcePending else { return }
        model.resolveOriginal(text)
        sourcePending = false
        processIfReady()
    }

    func finish(runRewrite: Bool = true) {
        guard stage == .listening else { return }
        let id = generation
        stage = .transcribing
        stoppedAt = .now
        level = 0
        autoRewrite = runRewrite
        limitTask?.cancel()
        task = Task { [weak self, recorder, deleteAudio] in
            do {
                let url = try await recorder.stop()
                guard let self, self.generation == id, !Task.isCancelled else { deleteAudio(url); return }
                self.audioURL = url
                self.task = nil
                self.processIfReady()
            } catch {
                guard let self, self.generation == id else { return }
                self.fail("Could not finish instruction recording. Review or type your instructions below.")
            }
        }
    }

    func expand() {
        expanded = true
        autoRewrite = false
        if stage == .listening { finish(runRewrite: false) }
    }

    private func processIfReady() {
        guard stage == .transcribing, !sourcePending, let url = audioURL else { return }
        audioURL = nil
        let id = generation
        limitTask = Task { [weak self, transcriptionLimit] in
            do { try await Task.sleep(for: transcriptionLimit) } catch { return }
            guard let self, self.generation == id, self.stage == .transcribing else { return }
            self.fail("Instruction transcription timed out. Review the live text or type instructions; your source is safe.")
        }
        task = Task { [weak self, transcribe, deleteAudio] in
            defer { deleteAudio(url) }
            do {
                let text = try await transcribe(url)
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.task = nil
                self.limitTask?.cancel()
                self.stage = .ready
                self.model.instructions = text
                if let start = self.stoppedAt {
                    let elapsed = start.duration(to: .now).components
                    let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                    Self.logger.info("Instruction finalization completed milliseconds=\(ms)")
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.expanded = true
                    self.notice = "No instruction speech was detected. Choose a preset or type instructions."
                    self.model.action = .clean
                } else if self.autoRewrite {
                    self.model.start()
                    if !self.model.isRunning { self.expanded = true }
                }
            } catch {
                guard let self, self.generation == id else { return }
                self.fail("Instruction transcription failed. The live preview may be incomplete; review or type your instructions.")
            }
        }
    }

    private func fail(_ message: String) {
        generation = UUID()
        task?.cancel()
        if let audioURL { deleteAudio(audioURL) }
        audioURL = nil
        recorder.cancel()
        limitTask?.cancel()
        stage = .ready
        level = 0
        expanded = true
        autoRewrite = false
        notice = message
        model.restoreDraft()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        limitTask?.cancel()
        recorder.cancel()
        if let audioURL { deleteAudio(audioURL) }
        audioURL = nil
        sourcePending = false
        stage = .inactive
        level = 0
        model.cancel()
    }
}
