// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YuEStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "YuEStudio", path: "Sources/YuEStudio",
                          swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        .testTarget(name: "StudioTests", dependencies: ["YuEStudio"])
    ]
)
