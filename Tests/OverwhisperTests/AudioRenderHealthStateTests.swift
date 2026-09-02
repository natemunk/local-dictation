import AudioToolbox
import Testing
@testable import LocalDictation

@Suite("Audio render health state")
struct AudioRenderHealthStateTests {
    @Test("watchdog is seeded only when the audio unit is about to start")
    func watchdogStartSeed() {
        let state = AudioRenderHealthState()

        #expect(state.lastCallbackTick == 0)

        state.resetForAudioUnitStart(at: 123)
        #expect(state.lastCallbackTick == 123)

        state.recordCallback(at: 456)
        #expect(state.lastCallbackTick == 456)
    }

    @Test("successful callbacks clear transient render failures")
    func transientFailureRecovery() {
        let state = AudioRenderHealthState()
        let transientError = OSStatus(-50)

        state.recordRenderFailure(transientError)
        state.recordRenderFailure(transientError)
        #expect(state.consecutiveRenderFailureCount == 2)
        #expect(state.lastRenderError == transientError)
        #expect(state.terminalRenderError == nil)

        state.recordRenderSuccess()
        #expect(state.consecutiveRenderFailureCount == 0)
        #expect(state.lastRenderError == nil)
        #expect(state.terminalRenderError == nil)
    }

    @Test("three consecutive render failures are terminal")
    func repeatedFailuresAreTerminal() {
        let state = AudioRenderHealthState()
        let persistentError = OSStatus(-10_860)

        for _ in 0..<AudioRenderHealthState.terminalConsecutiveFailureThreshold {
            state.recordRenderFailure(persistentError)
        }

        #expect(
            state.consecutiveRenderFailureCount
                == AudioRenderHealthState.terminalConsecutiveFailureThreshold
        )
        #expect(state.terminalRenderError == persistentError)

        state.resetForAudioUnitStart(at: 789)
        #expect(state.consecutiveRenderFailureCount == 0)
        #expect(state.lastRenderError == nil)
        #expect(state.terminalRenderError == nil)
    }
}
