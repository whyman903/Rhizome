// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyWiki",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MyWikiCore", targets: ["MyWikiCore"]),
        .executable(name: "MyWiki", targets: ["MyWikiApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.7.1"),
    ],
    targets: [
        .target(
            name: "MyWikiCore",
            path: "Sources/MyWikiCore"
        ),
        .executableTarget(
            name: "MyWikiApp",
            dependencies: [
                "MyWikiCore",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/MyWikiApp",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/web"),
            ]
        ),
        .testTarget(
            name: "MyWikiCoreTests",
            dependencies: ["MyWikiCore"],
            path: "Tests/MyWikiCoreTests"
        ),
        .testTarget(
            name: "MyWikiAppTests",
            dependencies: ["MyWikiApp"],
            path: "Tests/MyWikiAppTests"
        ),
    ]
)
