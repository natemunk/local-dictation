import Foundation

final class AtomicJSONLCheckpointWriter<Record: Encodable> {
    let outputURL: URL
    let partialURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private var records: [Record] = []

    init(
        outputURL: URL,
        overwrite: Bool,
        fileManager: FileManager = .default
    ) throws {
        self.outputURL = outputURL.standardizedFileURL
        partialURL = URL(fileURLWithPath: self.outputURL.path + ".partial")
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let parent = self.outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CorpusRunnerFailure.output(
                "Output directory does not exist: \(parent.path)"
            )
        }

        if !overwrite {
            if fileManager.fileExists(atPath: self.outputURL.path) {
                throw CorpusRunnerFailure.unsafeOutput(
                    "Output already exists; pass --overwrite to replace it: \(self.outputURL.path)"
                )
            }
            if fileManager.fileExists(atPath: partialURL.path) {
                throw CorpusRunnerFailure.unsafeOutput(
                    "A partial checkpoint already exists; preserve it or pass --overwrite: \(partialURL.path)"
                )
            }
        }
    }

    func append(_ record: Record) throws {
        records.append(record)
        try write(records, to: partialURL)
    }

    func finalize() throws {
        try write(records, to: outputURL)
        if fileManager.fileExists(atPath: partialURL.path) {
            do {
                try fileManager.removeItem(at: partialURL)
            } catch {
                throw CorpusRunnerFailure.output(
                    "Published results but could not remove partial checkpoint at \(partialURL.path): \(error.localizedDescription)"
                )
            }
        }
    }

    private func write(_ records: [Record], to url: URL) throws {
        do {
            var data = Data()
            for record in records {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try data.write(to: url, options: .atomic)
        } catch let error as CorpusRunnerFailure {
            throw error
        } catch {
            throw CorpusRunnerFailure.output(
                "Cannot atomically write \(url.path): \(error.localizedDescription)"
            )
        }
    }
}
