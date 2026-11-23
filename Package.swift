// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZooDirector",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZooDirector", targets: ["ZooDirector"]),
               .executable(name: "ZooDirectorSSHAskpass", targets: ["ZooDirectorSSHAskpass"])],
    targets: [
        .executableTarget(name: "ZooDirector", resources: [.copy("Resources/Localization")]),
        .executableTarget(name: "ZooDirectorSSHAskpass"),
        .testTarget(name: "ZooDirectorTests", dependencies: ["ZooDirector"])
    ]
)
