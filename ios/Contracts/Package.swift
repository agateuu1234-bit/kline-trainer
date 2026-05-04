// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlineTrainerContracts",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KlineTrainerContracts", targets: ["KlineTrainerContracts"]),
        .library(name: "KlineTrainerPersistence", targets: ["KlineTrainerPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", "6.29.0"..<"7.0.0"),
        // PR4a：P2 ZipExtracting / ZipIntegrityVerifying 用 ZipFoundation Archive + Data.crc32(IEEE)。
        // 选型理由：iOS 无内建 zip 解压（AppleArchive 只支持 .aar）；纯 Swift / MIT / SwiftPM 一行。
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", "0.9.0"..<"1.0.0"),
    ],
    targets: [
        .target(name: "KlineTrainerContracts", path: "Sources/KlineTrainerContracts"),
        .target(
            name: "KlineTrainerPersistence",
            dependencies: [
                "KlineTrainerContracts",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/KlineTrainerPersistence"
        ),
        .testTarget(
            name: "KlineTrainerContractsTests",
            dependencies: ["KlineTrainerContracts"],
            path: "Tests/KlineTrainerContractsTests",
            resources: [.copy("fixtures")]
        ),
        .testTarget(
            name: "KlineTrainerPersistenceTests",
            dependencies: [
                "KlineTrainerPersistence",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Tests/KlineTrainerPersistenceTests"
        ),
    ]
)
