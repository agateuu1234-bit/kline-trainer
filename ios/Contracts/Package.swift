// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlineTrainerContracts",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "KlineTrainerContracts",
            targets: ["KlineTrainerContracts"]
        ),
    ],
    targets: [
        .target(
            name: "KlineTrainerContracts",
            path: "Sources/KlineTrainerContracts"
        ),
        .testTarget(
            name: "KlineTrainerContractsTests",
            dependencies: ["KlineTrainerContracts"],
            path: "Tests/KlineTrainerContractsTests",
            resources: [
                .copy("fixtures")
            ]
        ),
    ]
)
