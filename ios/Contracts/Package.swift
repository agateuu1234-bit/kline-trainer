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
        .library(
            name: "KlineTrainerPersistence",
            targets: ["KlineTrainerPersistence"]
        ),
    ],
    dependencies: [
        // GRDB 6.29.x：与 ios/KlineTrainer/KlineTrainer.xcodeproj 现有 pin (upToNextMajor 6.29.0)
        // 一致，避免 SwiftPM 单版本解析冲突（codex round 1 HIGH-1）。
        // 6.29 已支持 read-only DatabaseQueue / PRAGMA / @preconcurrency import；
        // Swift 6 strict-concurrency 由 @preconcurrency import GRDB 兜底。
        .package(url: "https://github.com/groue/GRDB.swift.git", "6.29.0"..<"7.0.0"),
    ],
    targets: [
        .target(
            name: "KlineTrainerContracts",
            path: "Sources/KlineTrainerContracts"
        ),
        .target(
            name: "KlineTrainerPersistence",
            dependencies: [
                "KlineTrainerContracts",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/KlineTrainerPersistence"
        ),
        .testTarget(
            name: "KlineTrainerContractsTests",
            dependencies: ["KlineTrainerContracts"],
            path: "Tests/KlineTrainerContractsTests",
            resources: [
                .copy("fixtures")
            ]
        ),
        .testTarget(
            name: "KlineTrainerPersistenceTests",
            dependencies: [
                "KlineTrainerPersistence",
                // 显式声明 GRDB（即使 transitive 可达）：fixture 直接 import GRDB 写测试 sqlite。
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/KlineTrainerPersistenceTests"
        ),
    ]
)
