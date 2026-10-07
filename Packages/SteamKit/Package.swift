// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteamKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SteamKit", targets: ["SteamKit"]),
        .executable(name: "steamkit-cli", targets: ["steamkit-cli"]),
    ],
    dependencies: [
        // Keep in step with the protoc-gen-swift used by Scripts/generate-protos.sh.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(
            name: "SteamKit",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        // Developer smoke test: connects to a real CM from the Mac. Not shipped in the app.
        .executableTarget(name: "steamkit-cli", dependencies: ["SteamKit"]),
        .testTarget(
            name: "SteamKitTests",
            dependencies: ["SteamKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
