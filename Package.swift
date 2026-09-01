// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Herdling",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(name: "Herdling"),
        .testTarget(
            name: "HerdlingTests",
            dependencies: ["Herdling", .product(name: "Testing", package: "swift-testing")]
        ),
    ]
)
