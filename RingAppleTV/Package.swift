// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift Package Manager required to build this package.

import PackageDescription

let package = Package(
    name: "RingAppleTV",
    platforms: [
        .tvOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "RingAppleTV",
            targets: ["RingAppleTV"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0")
    ],
    targets: [
        .target(
            name: "RingAppleTV",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "RingAppleTVTests",
            dependencies: [
                "RingAppleTV",
                "SwiftCheck"
            ],
            path: "Tests"
        )
    ]
)
