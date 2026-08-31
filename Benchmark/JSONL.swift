import Foundation

enum JSONL {
    static func decode<T: Decodable>(_ type: T.Type, from path: String) throws -> [T] {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchmarkFailure(message: "Cannot read \(path): \(error.localizedDescription)")
        }

        guard var text = String(data: data, encoding: .utf8) else {
            throw BenchmarkFailure(message: "\(path) is not valid UTF-8")
        }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }

        let decoder = JSONDecoder()
        var decoded: [T] = []
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                decoded.append(try decoder.decode(T.self, from: Data(trimmed.utf8)))
            } catch {
                throw BenchmarkFailure(
                    message: "Invalid JSONL record at \(path):\(offset + 1): \(error.localizedDescription)"
                )
            }
        }
        return decoded
    }
}
