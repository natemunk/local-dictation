import Foundation
import TOMLKit

enum ConfigurationDocumentStage: String {
    case read
    case parse
    case decode
    case encode
}

struct ConfigurationDocumentError: Error {
    let stage: ConfigurationDocumentStage
    let fileURL: URL?
    let underlying: any Error

    var message: String {
        "\(stage.rawValue.capitalized) failed: \(String(describing: underlying))"
    }
}

enum TOMLDocumentCodec {
    static func decode<Value: Decodable>(_ type: Value.Type, from fileURL: URL) throws -> Value {
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ConfigurationDocumentError(stage: .read, fileURL: fileURL, underlying: error)
        }

        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            throw ConfigurationDocumentError(stage: .parse, fileURL: fileURL, underlying: error)
        }

        do {
            return try TOMLDecoder().decode(type, from: table)
        } catch {
            throw ConfigurationDocumentError(stage: .decode, fileURL: fileURL, underlying: error)
        }
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            let table: TOMLTable = try TOMLEncoder().encode(value)
            var text = table.convert(to: .toml)
            if !text.hasSuffix("\n") { text.append("\n") }
            return Data(text.utf8)
        } catch {
            throw ConfigurationDocumentError(stage: .encode, fileURL: nil, underlying: error)
        }
    }
}
