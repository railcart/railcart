// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RailcartChain",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RailcartChain", targets: ["RailcartChain"]),
    ],
    dependencies: [
        .package(path: "../../vendor/swift-secp256k1"),
        .package(path: "../../vendor/BigInt"),
    ],
    targets: [
        .target(
            name: "RailcartChain",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            swiftSettings: [
                .define("ENABLE_MODULE_RECOVERY"),
            ]
        ),
        .testTarget(
            name: "RailcartChainTests",
            dependencies: ["RailcartChain"]
        ),
    ]
)
