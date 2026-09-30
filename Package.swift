// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SecretShot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SecretShot",
            path: "Sources/SecretShot"
        )
    ]
)
