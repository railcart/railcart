// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RailcartCrypto",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RailcartCrypto", targets: ["RailcartCrypto"]),
    ],
    dependencies: [
        .package(path: "../../vendor/BigInt"),
    ],
    targets: [
        .systemLibrary(
            name: "CSodium",
            pkgConfig: "libsodium",
            providers: [.brew(["libsodium"])]
        ),
        .target(
            name: "RailcartCrypto",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                "CSodium",
            ]
        ),
        .testTarget(
            name: "RailcartCryptoTests",
            dependencies: ["RailcartCrypto"]
        ),
    ]
)
