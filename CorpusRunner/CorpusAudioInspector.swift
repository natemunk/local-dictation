@preconcurrency import AVFoundation
import CryptoKit
import Foundation

protocol CorpusAudioInspecting: Sendable {
    func inspect(audioURL: URL, declaredDuration: Double) throws -> CorpusAudioInspection
}

struct ProductionCorpusAudioInspector: CorpusAudioInspecting {
    func inspect(audioURL: URL, declaredDuration: Double) throws -> CorpusAudioInspection {
        let values: URLResourceValues
        do {
            values = try audioURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
        } catch {
            throw CorpusRunnerFailure.input(
                "Cannot inspect audio at \(audioURL.path): \(error.localizedDescription)"
            )
        }
        guard values.isRegularFile == true else {
            throw CorpusRunnerFailure.input(
                "Manifest audio is not a regular file: \(audioURL.path)"
            )
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw CorpusRunnerFailure.input(
                "Cannot decode audio at \(audioURL.path): \(error.localizedDescription)"
            )
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, audioFile.length > 0 else {
            throw CorpusRunnerFailure.input(
                "Audio has no measurable duration: \(audioURL.path)"
            )
        }
        let measuredDuration = Double(audioFile.length) / sampleRate
        let tolerance = max(0.100, declaredDuration * 0.01)
        guard abs(measuredDuration - declaredDuration) <= tolerance else {
            throw CorpusRunnerFailure.input(
                "Manifest duration mismatch for \(audioURL.lastPathComponent): declared \(declaredDuration)s, measured \(measuredDuration)s"
            )
        }

        let digest = try sha256AndByteCount(of: audioURL)
        return CorpusAudioInspection(
            durationSeconds: measuredDuration,
            byteCount: digest.byteCount,
            sha256: digest.sha256
        )
    }

    private func sha256AndByteCount(of url: URL) throws -> (sha256: String, byteCount: UInt64) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CorpusRunnerFailure.input(
                "Cannot hash audio at \(url.path): \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
                byteCount += UInt64(chunk.count)
            }
        } catch {
            throw CorpusRunnerFailure.input(
                "Cannot hash audio at \(url.path): \(error.localizedDescription)"
            )
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (sha256, byteCount)
    }
}

enum CorpusDigest {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
