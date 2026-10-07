import Foundation
import Testing
@testable import LocalDictation

@Suite("Capture readiness and recovery")
struct CaptureReadinessTests {
    @Test func distinguishesMissingSilentAndAudibleInput() {
        #expect(CaptureInputEvidence.classify(frames: 0, peakRMS: 1, heardAudio: true).emptyTranscriptReason == .noAudioFrames)
        #expect(CaptureInputEvidence.classify(frames: 16000, peakRMS: 0.00001, heardAudio: false).emptyTranscriptReason == .lowInputEnergy)
        #expect(CaptureInputEvidence.classify(frames: 1000, peakRMS: 0.01, heardAudio: false).emptyTranscriptReason == .noSpeech)
        #expect(CaptureInputEvidence.classify(frames: 1000, peakRMS: 0, heardAudio: true).emptyTranscriptReason == .noSpeech)
        #expect(DictationFailureReason.noSpeech.isNeutral)
        #expect(DictationFailureReason.lowInputEnergy.isNeutral)
        #expect(!DictationFailureReason.noAudioFrames.isNeutral)
    }

    @Test func firstFrameIsPublishedOnceAndResetPerStart() {
        let health = AudioRenderHealthState()
        health.resetForAudioUnitStart(at: 100)
        health.recordCallback(at: 110)
        health.recordRenderFailure(-1)
        #expect(health.firstFrameTick == 0)
        health.recordPublishedFrame(at: 120)
        health.recordPublishedFrame(at: 130)
        #expect(health.firstFrameTick == 120)
        #expect(health.audioUnitStartTick == 100)
        health.resetForAudioUnitStart(at: 200)
        #expect(health.firstFrameTick == 0)
        #expect(health.audioUnitStartTick == 200)
    }

    @Test func readinessDoesNotReplaceTypingOrNewSessionState() {
        #expect(CaptureReadinessPolicy.shouldShowStarting(current: true, recording: true, receivedFrame: false, typing: false))
        #expect(!CaptureReadinessPolicy.shouldShowStarting(current: false, recording: true, receivedFrame: false, typing: false))
        #expect(!CaptureReadinessPolicy.shouldShowStarting(current: true, recording: false, receivedFrame: false, typing: false))
        #expect(!CaptureReadinessPolicy.shouldShowStarting(current: true, recording: true, receivedFrame: true, typing: false))
        #expect(!CaptureReadinessPolicy.shouldShowStarting(current: true, recording: true, receivedFrame: false, typing: true))
    }

    @Test @MainActor func staleFirstFrameCannotMutateReplacement() throws {
        let coordinator = DictationCoordinator()
        let controller = DictationSessionController()
        let first = try #require(coordinator.hotkeyDown(at: 1, profileMode: .clean).effects.first)
        guard case .startCapture(let old) = first else { Issue.record("Capture expected"); return }
        _ = coordinator.escapePressed()
        let second = try #require(coordinator.hotkeyDown(at: 2, profileMode: .clean).effects.first)
        guard case .startCapture(let new) = second else { Issue.record("Replacement expected"); return }
        controller.install(DictationSession(token: new, startedAt: Date(), engine: nil,
            streamingTranscriber: nil, asrSelection: .parakeetV2, profile: ProfileCatalog.nativeDefaults["default"]!))
        #expect(!controller.update(old) { $0.firstAudioFrameAtUptime = 1.2 })
        #expect(controller.active?.firstAudioFrameAtUptime == nil)
    }
}
