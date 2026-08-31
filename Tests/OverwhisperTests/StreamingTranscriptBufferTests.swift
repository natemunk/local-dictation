import Testing
@testable import LocalDictation

@Suite("Streaming transcript replacement")
struct StreamingTranscriptBufferTests {
    @Test("volatile updates replace instead of append")
    func volatileReplacement() {
        var buffer = TranscriptBuffer()

        buffer.apply(TranscriptUpdate(finalized: "", volatile: "hello wor"))
        buffer.apply(TranscriptUpdate(finalized: "", volatile: "hello world"))

        #expect(buffer.finalized == "")
        #expect(buffer.volatile == "hello world")
        #expect(buffer.text == "hello world")
    }

    @Test("finalized and volatile ranges are replaced atomically")
    func atomicRangeReplacement() {
        var buffer = TranscriptBuffer()
        buffer.apply(TranscriptUpdate(finalized: "hello", volatile: "world"))
        buffer.apply(TranscriptUpdate(finalized: "hello there", volatile: "friend"))

        #expect(buffer.finalized == "hello there")
        #expect(buffer.volatile == "friend")
        #expect(buffer.text == "hello there friend")
    }

    @Test("final commit clears stale volatile text")
    func finalCommit() {
        var buffer = TranscriptBuffer()
        buffer.apply(TranscriptUpdate(finalized: "hello", volatile: "worl"))
        buffer.commit(FinalTranscript(text: "hello world", language: "en"))

        #expect(buffer.finalized == "hello world")
        #expect(buffer.volatile.isEmpty)
        #expect(buffer.text == "hello world")
    }
}
