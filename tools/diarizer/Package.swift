// swift-tools-version:5.9
// Standalone helper package: speaker diarization for the Ambient Context
// Stream. Deliberately NOT a dependency of the main ClawGate package — the
// app stays macOS 12 / universal (Intel servers, older client Macs), while
// this helper needs macOS 14+ / Apple Silicon (FluidAudio CoreML/ANE).
// Provisioned out-of-repo like whisper-cli; absent helper = diarization off.
import PackageDescription

let package = Package(
    name: "clawgate-diarizer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.2"),
    ],
    targets: [
        .executableTarget(
            name: "clawgate-diarizer",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Diarizer"
        ),
    ]
)
