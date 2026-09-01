import Testing
@testable import LocalDictation

@Suite("Audio frame accounting")
struct AudioFrameAccountingTests {
    @Test("converted capacities round up instead of truncating")
    func capacitiesUseCeiling() {
        #expect(
            AudioFrameSizing.convertedCapacity(
                inputFrameCapacity: 512,
                inputSampleRate: 44_100,
                outputSampleRate: 16_000
            ) == 186
        )
        #expect(
            AudioFrameSizing.convertedCapacity(
                inputFrameCapacity: 512,
                inputSampleRate: 48_000,
                outputSampleRate: 16_000
            ) == 171
        )
        #expect(
            AudioFrameSizing.convertedCapacity(
                inputFrameCapacity: 512,
                inputSampleRate: 96_000,
                outputSampleRate: 16_000
            ) == 86
        )
    }

    @Test("44.1, 48, and 96 kHz each map one second to exactly 16k samples")
    func standardRatesHaveExactOneSecondTotals() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            var accounting = AudioFrameAccounting(inputSampleRate: rate)
            var remaining = Int(rate)
            while remaining > 0 {
                let block = min(512, remaining)
                accounting.acceptInput(frames: block)
                remaining -= block
            }

            #expect(accounting.expectedOutputFrames == 16_000)
            #expect(accounting.pendingOutputFrames == 16_000)
            let accepted = accounting.recordEmission(frames: 16_000)
            #expect(accepted)
            #expect(accounting.pendingOutputFrames == 0)
        }
    }

    @Test("fractional output frames carry across callback boundaries")
    func fractionalFramesCarryAcrossBlocks() {
        var accounting = AudioFrameAccounting(inputSampleRate: 44_100)

        accounting.acceptInput(frames: 1)
        #expect(accounting.expectedOutputFrames == 0)
        accounting.acceptInput(frames: 440)
        #expect(accounting.expectedOutputFrames == 160)
        let accepted = accounting.recordEmission(frames: 159)
        #expect(accepted)
        #expect(accounting.pendingOutputFrames == 1)

        accounting.acceptInput(frames: 441)
        #expect(accounting.expectedOutputFrames == 320)
        #expect(accounting.pendingOutputFrames == 161)
    }

    @Test("the writer rejects output beyond accepted source duration")
    func overEmissionIsRejected() {
        var accounting = AudioFrameAccounting(inputSampleRate: 48_000)
        accounting.acceptInput(frames: 480)

        #expect(accounting.pendingOutputFrames == 160)
        let rejected = accounting.recordEmission(frames: 161)
        #expect(!rejected)
        #expect(accounting.emittedOutputFrames == 0)
        let accepted = accounting.recordEmission(frames: 160)
        #expect(accepted)
    }
}
