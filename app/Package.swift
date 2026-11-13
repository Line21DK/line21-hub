// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LINE21Hub",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LINE21Hub", targets: ["LINE21Hub"])],
    targets: [
        .target(name: "HubCore", path: "Sources/HubCore"),
        .executableTarget(name: "LINE21Hub", dependencies: ["HubCore"], path: "Sources/LINE21Hub"),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"], path: "Tests/HubCoreTests"),
    ]
)
