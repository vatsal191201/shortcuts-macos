// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyPeek",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KeyPeek", targets: ["KeyPeek"]),
        .library(name: "KeyPeekCore", targets: ["KeyPeekCore"]),
    ],
    targets: [
        .target(name: "KeyPeekCore"),
        .executableTarget(name: "KeyPeek", dependencies: ["KeyPeekCore"]),
        // The tests read Fixtures/ and Resources/semantic-model.bin by file path.
        .testTarget(name: "KeyPeekCoreTests", dependencies: ["KeyPeekCore"], exclude: ["Fixtures"]),
    ]
)
