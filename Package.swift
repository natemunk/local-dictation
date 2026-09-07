// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LocalDictationSpeech", targets: ["LocalDictationSpeech"]),
        .executable(name: "LocalDictation", targets: ["LocalDictation"]),
        .executable(name: "local-dictation-benchmark", targets: ["LocalDictationBenchmark"]),
        .executable(
            name: "local-dictation-corpus-runner",
            targets: ["LocalDictationCorpusRunner"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.15.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
            exact: "2.7.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            exact: "2.12.0"
        )
    ],
    targets: [
        .target(
            name: "LocalDictationSpeech",
            dependencies: [
                "WhisperKit",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Overwhisper/SpeechLayer"
        ),
        .executableTarget(
            name: "LocalDictation",
            dependencies: [
                "LocalDictationSpeech",
                "WhisperKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
            ],
            path: "Overwhisper",
            exclude: [
                "Info.plist",
                "Overwhisper.entitlements",
                "SpeechLayer"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "LocalDictationBenchmark",
            path: "Benchmark",
            exclude: ["Fixtures", "Schemas", "README.md", "verify-fixtures.sh"]
        ),
        .executableTarget(
            name: "LocalDictationCorpusRunner",
            dependencies: ["LocalDictationSpeech"],
            path: "CorpusRunner"
        ),
        .testTarget(
            name: "LocalDictationTests",
            dependencies: [
                "LocalDictation",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket")
            ],
            path: "Tests/OverwhisperTests"
        ),
        .testTarget(
            name: "LocalDictationCorpusRunnerTests",
            dependencies: [
                "LocalDictationSpeech",
                "LocalDictationCorpusRunner"
            ],
            path: "Tests/CorpusRunnerTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
