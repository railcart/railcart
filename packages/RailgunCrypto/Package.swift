// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RailgunCrypto",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RailgunCrypto", targets: ["RailgunCrypto"]),
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
        .binaryTarget(
            name: "RsPoseidon",
            path: "../../vendor/rs-poseidon/RsPoseidon.xcframework"
        ),
        .target(
            name: "RailgunCrypto",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                "CSodium",
                "RsPoseidon",
            ]
        ),
        .testTarget(
            name: "RailgunCryptoTests",
            dependencies: ["RailgunCrypto"]
        ),
    ]
)
