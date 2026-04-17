// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EVMKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EVMKit", targets: ["EVMKit"]),
    ],
    dependencies: [
        .package(path: "../../vendor/swift-secp256k1"),
        .package(path: "../../vendor/BigInt"),
    ],
    targets: [
        .target(
            name: "EVMKit",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            swiftSettings: [
                .define("ENABLE_MODULE_RECOVERY"),
            ]
        ),
        .testTarget(
            name: "EVMKitTests",
            dependencies: ["EVMKit"]
        ),
    ]
)
