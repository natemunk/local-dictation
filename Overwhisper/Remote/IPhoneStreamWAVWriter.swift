import Foundation

enum IPhoneStreamWAVError: Error, Equatable, Sendable {
    case invalidFrame
    case tooLong
    case closed
    case fileCreationFailed
}

struct IPhoneStreamedAudio: Sendable {
    let wavURL: URL
    let durationSeconds: TimeInterval

    func removeFile(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: wavURL)
    }
}

actor IPhoneStreamWAVWriter {
    static let sampleRate = 16_000
    static let maximumFrameBytes = 64 * 1_024
    static let maximumSamples = sampleRate * Int(IPhoneTranscriptionRequest.maximumDurationSeconds)

    private let fileManager: FileManager
    private let url: URL
    private var handle: FileHandle?
    private var sampleCount = 0

    init(
        requestID: UUID,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        self.fileManager = fileManager
        url = temporaryDirectory.appendingPathComponent(
            "local-dictation-iphone-\(requestID.uuidString.lowercased())-stream-16k.wav"
        )
        try? fileManager.removeItem(at: url)
        guard fileManager.createFile(atPath: url.path, contents: Self.wavHeader(dataBytes: 0)),
              let fileHandle = try? FileHandle(forWritingTo: url)
        else { throw IPhoneStreamWAVError.fileCreationFailed }
        handle = fileHandle
        do {
            try fileHandle.seekToEnd()
        } catch {
            try? fileHandle.close()
            try? fileManager.removeItem(at: url)
            throw IPhoneStreamWAVError.fileCreationFailed
        }
    }

    func append(_ data: Data) throws -> [Float] {
        guard let handle else { throw IPhoneStreamWAVError.closed }
        guard !data.isEmpty,
              data.count <= Self.maximumFrameBytes,
              data.count.isMultiple(of: MemoryLayout<Int16>.size)
        else { throw IPhoneStreamWAVError.invalidFrame }

        let incomingSamples = data.count / MemoryLayout<Int16>.size
        guard sampleCount + incomingSamples <= Self.maximumSamples else {
            throw IPhoneStreamWAVError.tooLong
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw IPhoneStreamWAVError.fileCreationFailed
        }
        sampleCount += incomingSamples

        return data.withUnsafeBytes { rawBytes in
            let words = rawBytes.bindMemory(to: Int16.self)
            return words.map { word in
                Float(Int16(littleEndian: word)) / 32_768
            }
        }
    }

    func finish() throws -> IPhoneStreamedAudio {
        guard let handle else { throw IPhoneStreamWAVError.closed }
        guard sampleCount > 0 else { throw IPhoneStreamWAVError.invalidFrame }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.wavHeader(dataBytes: sampleCount * 2))
            try handle.synchronize()
            try handle.close()
            self.handle = nil
        } catch {
            try? handle.close()
            self.handle = nil
            try? fileManager.removeItem(at: url)
            throw IPhoneStreamWAVError.fileCreationFailed
        }
        return IPhoneStreamedAudio(
            wavURL: url,
            durationSeconds: TimeInterval(sampleCount) / TimeInterval(Self.sampleRate)
        )
    }

    func cancel() {
        try? handle?.close()
        handle = nil
        try? fileManager.removeItem(at: url)
    }

    private nonisolated static func wavHeader(dataBytes: Int) -> Data {
        var bytes = Data()
        bytes.append(contentsOf: Array("RIFF".utf8))
        bytes.appendLittleEndian(UInt32(36 + dataBytes))
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("fmt ".utf8))
        bytes.appendLittleEndian(UInt32(16))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt32(sampleRate))
        bytes.appendLittleEndian(UInt32(sampleRate * 2))
        bytes.appendLittleEndian(UInt16(2))
        bytes.appendLittleEndian(UInt16(16))
        bytes.append(contentsOf: Array("data".utf8))
        bytes.appendLittleEndian(UInt32(dataBytes))
        return bytes
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
