// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZooDirector",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZooDirector", targets: ["ZooDirector"])],
    targets: [
        .executableTarget(name: "ZooDirector", resources: [.copy("Resources/Localization")]),
        .testTarget(name: "ZooDirectorTests", dependencies: ["ZooDirector"])
    ]
)
