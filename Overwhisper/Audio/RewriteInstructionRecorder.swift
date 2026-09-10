import Foundation
import Combine

@MainActor
protocol RewriteInstructionRecording: AnyObject {
    func start(onPartial: @escaping (String) -> Void, onLevel: @escaping (Float) -> Void,
               onFailure: @escaping () -> Void) throws
    func stop() async throws -> URL
    func cancel()
}

/// A separate, short-lived microphone session. It never enters debug/history
/// capture and cannot mix instruction samples with the original dictation.
@MainActor
final class RewriteInstructionRecorder: RewriteInstructionRecording {
    private let recorder = AudioRecorder()
    private let selectedDevice: () -> AudioInputDevice?
    private let preview: any StreamingTranscriber
    private var previewTask: Task<Void, Never>?
    private var previewDrain: Task<Void, Never>?
    private var meter: AnyCancellable?

    init(selectedDevice: @escaping () -> AudioInputDevice?,
         preview: any StreamingTranscriber = FluidAudioParakeetStreamingTranscriber()) {
        self.selectedDevice = selectedDevice
        self.preview = preview
    }

    func start(onPartial: @escaping (String) -> Void, onLevel: @escaping (Float) -> Void,
               onFailure: @escaping () -> Void) throws {
        recorder.setInputDevice(selectedDevice())
        recorder.onCaptureFailure = { _ in onFailure() }
        recorder.onCallbackLoss = { if $0 != .none { onFailure() } }
        let samples = try recorder.startRecording()
        meter = recorder.$currentLevel.sink(receiveValue: onLevel)
        let priorDrain = previewDrain
        previewTask = Task { [preview] in
            await priorDrain?.value
            guard !Task.isCancelled else { return }
            do {
                let updates = try await preview.start(samples: samples)
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    onPartial(LiveTranscript(finalized: update.finalized, volatile: update.volatile).displayed)
                }
            } catch {
                // Preview is optional; final local ASR still uses the WAV.
                AppLogger.transcription.notice("Instruction live preview unavailable")
            }
        }
    }

    func stop() async throws -> URL {
        let stopped = try recorder.stopCapture()
        stopPreview()
        return try await recorder.finishStoppedRecording(stopped)
    }

    func cancel() {
        recorder.cancelRecording()
        stopPreview()
    }

    private func stopPreview() {
        meter = nil
        previewTask?.cancel()
        let task = previewTask
        let priorDrain = previewDrain
        previewTask = nil
        previewDrain = Task { [preview] in
            await priorDrain?.value
            await preview.cancel()
            await task?.value
        }
    }
}
