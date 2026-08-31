import Foundation

struct ConfigurationPaths: Equatable, Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    static var userDefault: ConfigurationPaths {
        ConfigurationPaths(
            rootDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("local-dictation", isDirectory: true)
        )
    }

    var appFile: URL {
        rootDirectory.appendingPathComponent("app.toml", isDirectory: false)
    }

    var profilesFile: URL {
        rootDirectory.appendingPathComponent("profiles.toml", isDirectory: false)
    }

    var vocabularyDirectory: URL {
        rootDirectory.appendingPathComponent("vocabulary", isDirectory: true)
    }

    var globalVocabularyFile: URL {
        vocabularyDirectory.appendingPathComponent("global.toml", isDirectory: false)
    }

    var vocabularyPacksDirectory: URL {
        vocabularyDirectory.appendingPathComponent("packs", isDirectory: true)
    }

    var symphonyVocabularyFile: URL {
        vocabularyPackFile(id: "symphony")
    }

    var personalVocabularyFile: URL {
        vocabularyPackFile(id: "personal")
    }

    func vocabularyPackFile(id: String) -> URL {
        vocabularyPacksDirectory
            .appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("toml")
    }
}
