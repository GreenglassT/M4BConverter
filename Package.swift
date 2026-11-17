// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "M4BConverter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "M4BConverter"),
        .testTarget(name: "M4BConverterTests", dependencies: ["M4BConverter"]),
    ]
)
