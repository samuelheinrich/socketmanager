// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SocketManager",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "SocketManager", targets: ["SocketManager"])],
    targets: [
        .target(name: "SocketCore"),
        .executableTarget(name: "SocketManager", dependencies: ["SocketCore"]),
        .testTarget(name: "SocketCoreTests", dependencies: ["SocketCore"]),
        .testTarget(name: "SocketManagerTests", dependencies: ["SocketManager", "SocketCore"]),
    ]
)
