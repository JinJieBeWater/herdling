// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Herdling",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "Herdling",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "HerdlingTests",
            dependencies: ["Herdling", .product(name: "Testing", package: "swift-testing")]
        ),
    ]
)
