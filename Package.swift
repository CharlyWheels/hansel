// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hansel", targets: ["TimeTracker"])
    ],
    targets: [
        .executableTarget(
            name: "TimeTracker",
            path: "Sources/TimeTracker"
        ),
        .testTarget(
            name: "TimeTrackerTests",
            dependencies: ["TimeTracker"],
            path: "Tests/TimeTrackerTests"
        )
    ]
)
