// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HushKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HushCore", targets: ["HushCore"]),
        .library(name: "HotkeyService", targets: ["HotkeyService"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "Transcription", targets: ["Transcription"]),
        .library(name: "Cleanup", targets: ["Cleanup"]),
        .library(name: "Dictionary", targets: ["Dictionary"]),
        .library(name: "Insertion", targets: ["Insertion"]),
        .library(name: "EditWatcher", targets: ["EditWatcher"]),
        .library(name: "Media", targets: ["Media"]),
        .library(name: "Store", targets: ["Store"]),
    ],
    dependencies: [
        // WhisperKit (repo renamed to argmax-oss-swift; the WhisperKit product is unchanged)
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        // Cleanup LLM (MLXLLM + MLXVLM — Gemma 3 4B is a vision-language model)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        // HubApi (model downloads into AppPaths.modelsLLM) — also a transitive dep of mlx-swift-lm.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.1"),
        // SQLite store (T7)
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "HushCore"),
        .target(name: "HotkeyService", dependencies: ["HushCore"]),
        .target(name: "AudioCapture", dependencies: ["HushCore"]),
        .target(
            name: "Transcription",
            dependencies: [
                "HushCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(
            name: "Cleanup",
            dependencies: [
                "HushCore",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                // HubApi lives in swift-transformers' Hub product (transitive via MLXLMCommon).
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .target(name: "Dictionary", dependencies: ["HushCore"]),
        .target(name: "Insertion", dependencies: ["HushCore"]),
        .target(name: "EditWatcher", dependencies: ["HushCore"]),
        .target(name: "Media", dependencies: ["HushCore"]),
        .target(
            name: "Store",
            dependencies: [
                "HushCore",
                "AudioCapture",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .testTarget(name: "HushCoreTests", dependencies: ["HushCore"]),
        .testTarget(name: "HotkeyServiceTests", dependencies: ["HotkeyService"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription", "AudioCapture"]),
        .testTarget(name: "CleanupTests", dependencies: ["Cleanup"]),
        .testTarget(name: "DictionaryTests", dependencies: ["Dictionary"]),
        .testTarget(name: "InsertionTests", dependencies: ["Insertion"]),
        .testTarget(name: "EditWatcherTests", dependencies: ["EditWatcher"]),
        .testTarget(name: "MediaTests", dependencies: ["Media"]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
    ]
)
