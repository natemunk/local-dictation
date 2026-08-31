# Local Dictation development commands

swift := env_var_or_default("LOCAL_DICTATION_SWIFT", "swift")
cache_path := ".build/swiftpm-cache"

# List available commands.
default:
    @just --list

# Build the Local Dictation executable in debug mode.
build:
    "{{swift}}" build --disable-sandbox --cache-path "{{cache_path}}" --product LocalDictation

# Build the Local Dictation executable in release mode.
build-release:
    "{{swift}}" build --disable-sandbox --configuration release --cache-path "{{cache_path}}" --product LocalDictation

# Run unit and contract tests.
test:
    "{{swift}}" test --disable-sandbox --cache-path "{{cache_path}}"

# Run the debug app executable.
run:
    "{{swift}}" run --disable-sandbox --cache-path "{{cache_path}}" LocalDictation

# Resolve the pinned package graph.
resolve:
    "{{swift}}" package resolve --cache-path "{{cache_path}}"

# Show the resolved dependency tree.
deps:
    "{{swift}}" package show-dependencies --cache-path "{{cache_path}}"

# Check prohibited telemetry, updater, service, and cloud-ASR references.
privacy-audit:
    zsh scripts/privacy-audit.sh

# Build the standalone benchmark scorer.
benchmark-build:
    "{{swift}}" build --disable-sandbox --cache-path "{{cache_path}}" --product local-dictation-benchmark

# Validate checked-in benchmark fixtures and schemas.
benchmark-fixtures:
    bash Benchmark/verify-fixtures.sh

# Open the Swift package in Xcode. No generated project is required.
xcode:
    open Package.swift

# Run the documented source install and launch flow.
install:
    zsh ./setup

# Run the documented source install without launching the app.
install-no-launch:
    zsh ./setup --no-launch

# Remove SwiftPM build products using SwiftPM itself.
clean:
    "{{swift}}" package clean
