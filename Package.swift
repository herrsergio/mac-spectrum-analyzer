// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpectrumVisualizer",
    platforms: [
        // Pinned to 14.2: CoreAudio process-tap APIs are unavailable before this.
        // Do NOT lower to .v14 — build will fail with availability errors.
        .macOS("14.2")
    ],
    targets: [
        .executableTarget(
            name: "SpectrumVisualizer",
            path: "Sources/SpectrumVisualizer"
        )
    ]
)
