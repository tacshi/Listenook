// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ListenookSpeechWorker",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [
        // The iOS app links this and runs it in process.
        .library(name: "ListenookSpeechCore", targets: ["ListenookSpeechCore"]),
        // The macOS app runs this as a separate process.
        .executable(name: "ListenookSpeechWorker", targets: ["ListenookSpeechWorker"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/soniqo/speech-swift.git",
            revision: "13643ab4361da8f33c8002026c9d357ded0b6896"
        )
    ],
    targets: [
        .target(
            name: "ListenookSpeechCore",
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
        .executableTarget(
            name: "ListenookSpeechWorker",
            dependencies: ["ListenookSpeechCore"]
        ),
        .testTarget(
            name: "ListenookSpeechWorkerTests",
            dependencies: ["ListenookSpeechCore"]
        ),
    ]
)
