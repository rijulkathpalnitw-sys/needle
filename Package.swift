// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    .target(
        name: "NeedleCore",
        path: "Sources/NeedleCore"
    ),
    .executableTarget(
        name: "NeedleBench",
        dependencies: ["NeedleCore"],
        path: "Sources/NeedleBench"
    ),
    .testTarget(
        name: "NeedleCoreTests",
        dependencies: ["NeedleCore"],
        path: "Tests/NeedleCoreTests"
    ),
]

// The SwiftUI app only builds where SwiftUI exists.
#if os(macOS)
targets.append(
    .executableTarget(
        name: "NeedleApp",
        dependencies: ["NeedleCore"],
        path: "Sources/NeedleApp"
    )
)
#endif

let package = Package(
    name: "Needle",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "NeedleCore", targets: ["NeedleCore"]),
    ],
    targets: targets
)
