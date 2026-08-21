// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeowSTTSpeechWorker",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/soniqo/speech-swift.git",
            revision: "13643ab4361da8f33c8002026c9d357ded0b6896"
        )
    ],
    targets: [
        .executableTarget(
            name: "MeowSTTSpeechWorker",
            dependencies: [
                .product(name: "MossTranscribe", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("NaturalLanguage"),
            ]
        ),
        .testTarget(
            name: "MeowSTTSpeechWorkerTests",
            dependencies: ["MeowSTTSpeechWorker"]
        ),
    ]
)
