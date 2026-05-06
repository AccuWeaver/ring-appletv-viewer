// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift Package Manager required to build this package.

import PackageDescription

let package = Package(
    name: "RingAppleTV",
    platforms: [
        .tvOS(.v15)
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
        .binaryTarget(
            name: "WebRTC",
            path: "WebRTC.xcframework"
        ),
        .target(
            name: "RingAppleTV",
            dependencies: [
                .target(name: "WebRTC", condition: .when(platforms: [.iOS, .macOS, .tvOS]))
            ],
            path: "Sources",
            exclude: [
                "App/RingAppleTVApp.swift"
            ]
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
