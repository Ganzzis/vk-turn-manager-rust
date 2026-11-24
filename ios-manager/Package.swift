// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ServerManager",
    platforms: [.iOS(.v17), .macOS("15.0")],
    products: [.library(name: "ManagerCore", targets: ["ManagerCore"])],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.7"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(name: "ManagerCore", dependencies: [
            "Citadel",
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .testTarget(name: "ManagerCoreTests", dependencies: ["ManagerCore"])
    ]
)
