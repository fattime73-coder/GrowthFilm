// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrowthFilm",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GrowthFilm", targets: ["GrowthFilm"])],
    targets: [
        .target(name: "AlignmentCore"),
        .executableTarget(name: "GrowthFilm", dependencies: ["AlignmentCore"]),
        .testTarget(name: "AlignmentCoreTests", dependencies: ["AlignmentCore"])
    ]
)
