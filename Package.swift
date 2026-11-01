// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Herdrker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Herdrker", targets: ["Herdrker"])
    ],
    targets: [
        .executableTarget(
            name: "Herdrker",
            path: "Sources/Herdrker"
        ),
        .testTarget(
            name: "HerdrkerTests",
            dependencies: ["Herdrker"],
            path: "Tests/HerdrkerTests"
        )
    ]
)
