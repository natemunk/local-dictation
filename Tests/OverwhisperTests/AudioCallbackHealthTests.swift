import Testing
@testable import LocalDictation

@Suite("Audio callback health")
struct AudioCallbackHealthTests {
    @Test("meter, disconnect, and terminal thresholds are independent")
    func thresholds() {
        #expect(
            AudioCallbackHealthPolicy.evaluate(
                secondsSinceLastCallback: 0.249,
                capturedOutputFrames: 0
            ) == AudioCallbackHealth(
                shouldZeroMeter: false,
                isDisconnected: false,
                lossAction: .none
            )
        )
        #expect(
            AudioCallbackHealthPolicy.evaluate(
                secondsSinceLastCallback: 0.250,
                capturedOutputFrames: 0
            ).shouldZeroMeter
        )
        #expect(
            AudioCallbackHealthPolicy.evaluate(
                secondsSinceLastCallback: 0.500,
                capturedOutputFrames: 0
            ).isDisconnected
        )
        #expect(
            AudioCallbackHealthPolicy.evaluate(
                secondsSinceLastCallback: 1.999,
                capturedOutputFrames: 0
            ).lossAction == .none
        )
    }

    @Test("callback loss previews existing audio and fails empty capture")
    func terminalPolicy() {
        #expect(
            AudioCallbackHealthPolicy.evaluate(
                secondsSinceLastCallback: 2,
                capturedOutputFrames: 1
            ).lossAction == .finishInPreview
        )
        #expect(
            AudioCallbackHealthPolicy.evaluate(
                secondsSinceLastCallback: 2,
                capturedOutputFrames: 0
            ).lossAction == .fail
        )
    }
}
