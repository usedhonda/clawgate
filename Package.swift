// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ClawGate",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "ClawGate", targets: ["ClawGate"]),
        .executable(name: "ClawGateRelay", targets: ["ClawGateRelay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.67.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClawGate",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "ClawGate"
        ),
        .executableTarget(
            name: "ClawGateRelay",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "ClawGateRelay"
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["ClawGate"],
            path: "Tests/UnitTests"
        ),
    ]
)
