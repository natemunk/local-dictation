// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "LocalDictation", targets: ["LocalDictation"]),
        .executable(name: "local-dictation-benchmark", targets: ["LocalDictationBenchmark"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.15.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            dependencies: [
                "WhisperKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            path: "Overwhisper",
            exclude: [
                "Info.plist",
                "Overwhisper.entitlements"
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
        .testTarget(
            name: "LocalDictationTests",
            dependencies: ["LocalDictation"],
            path: "Tests/OverwhisperTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
