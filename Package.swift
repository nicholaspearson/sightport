// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SightportKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SightportCore", targets: ["SightportCore"])],
    targets: [
        .target(name: "SightportCore"),
        .testTarget(name: "SightportCoreTests", dependencies: ["SightportCore"])
    ]
)
