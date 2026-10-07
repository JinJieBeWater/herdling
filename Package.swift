// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Herdling",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "Herdling",
            dependencies: [.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
        ),
        .testTarget(
            name: "HerdlingTests",
            dependencies: ["Herdling", .product(name: "Testing", package: "swift-testing")]
        ),
    ]
)
