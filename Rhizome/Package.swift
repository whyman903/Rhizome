// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rhizome",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "RhizomeCore", targets: ["RhizomeCore"]),
        .executable(name: "Rhizome", targets: ["RhizomeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.7.1"),
    ],
    targets: [
        .target(
            name: "RhizomeCore",
            path: "Sources/RhizomeCore"
        ),
        .executableTarget(
            name: "RhizomeApp",
            dependencies: [
                "RhizomeCore",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/RhizomeApp",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/web"),
            ]
        ),
        .testTarget(
            name: "RhizomeCoreTests",
            dependencies: ["RhizomeCore"],
            path: "Tests/RhizomeCoreTests"
        ),
        .testTarget(
            name: "RhizomeAppTests",
            dependencies: ["RhizomeApp"],
            path: "Tests/RhizomeAppTests"
        ),
    ]
)
