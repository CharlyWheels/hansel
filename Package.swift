// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hansel", targets: ["TimeTracker"])
    ],
    dependencies: [
        // On-device speaker diarisation (pyannote + WeSpeaker on CoreML) for meetings.
        // The one third-party dependency: diarisation cannot reasonably be written by
        // hand, and this runs fully offline. Apache-2.0 / MIT.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5")
    ],
    targets: [
        .executableTarget(
            name: "TimeTracker",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/TimeTracker"
        ),
        .testTarget(
            name: "TimeTrackerTests",
            dependencies: ["TimeTracker"],
            path: "Tests/TimeTrackerTests"
        )
    ]
)
