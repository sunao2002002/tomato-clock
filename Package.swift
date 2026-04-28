// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "NTPClock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NTPClock", targets: ["NTPClock"])
    ],
    targets: [
        .executableTarget(
            name: "NTPClock"
        )
    ]
)