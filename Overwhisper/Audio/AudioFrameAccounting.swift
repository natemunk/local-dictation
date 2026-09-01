import Foundation

enum AudioFrameSizing {
    static func convertedCapacity(
        inputFrameCapacity: Int,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> Int {
        precondition(inputFrameCapacity > 0)
        precondition(inputSampleRate > 0)
        precondition(outputSampleRate > 0)
        return max(
            1,
            Int(
                ceil(
                    Double(inputFrameCapacity)
                        * outputSampleRate
                        / inputSampleRate
                )
            )
        )
    }
}

/// Tracks the canonical output length from cumulative input frames. Computing
/// from cumulative totals avoids losing a fractional frame at every callback.
struct AudioFrameAccounting: Equatable, Sendable {
    let inputSampleRate: Double
    let outputSampleRate: Double

    private(set) var acceptedInputFrames: Int64 = 0
    private(set) var emittedOutputFrames: Int64 = 0

    init(inputSampleRate: Double, outputSampleRate: Double = 16_000) {
        precondition(inputSampleRate > 0)
        precondition(outputSampleRate > 0)
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
    }

    mutating func acceptInput(frames: Int) {
        precondition(frames >= 0)
        acceptedInputFrames += Int64(frames)
    }

    var expectedOutputFrames: Int64 {
        Int64(
            floor(
                Double(acceptedInputFrames)
                    * outputSampleRate
                    / inputSampleRate
            )
        )
    }

    var pendingOutputFrames: Int64 {
        max(0, expectedOutputFrames - emittedOutputFrames)
    }

    /// Records frames actually written to the canonical WAV/stream. Returning
    /// false prevents a converter from extending the recording beyond the
    /// duration represented by the accepted native input frames.
    @discardableResult
    mutating func recordEmission(frames: Int) -> Bool {
        guard frames >= 0, Int64(frames) <= pendingOutputFrames else { return false }
        emittedOutputFrames += Int64(frames)
        return true
    }
}
