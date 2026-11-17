// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LINE21Control",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LINE21Control", targets: ["LINE21Control"])],
    targets: [
        .target(name: "ControlCore", path: "Sources/ControlCore"),
        .executableTarget(name: "LINE21Control", dependencies: ["ControlCore"], path: "Sources/LINE21Control"),
        .testTarget(name: "ControlCoreTests", dependencies: ["ControlCore"], path: "Tests/ControlCoreTests"),
    ]
)
