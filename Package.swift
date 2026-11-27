// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShortCuts",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShortCuts", targets: ["ShortCuts"]),
        .library(name: "ShortCutsCore", targets: ["ShortCutsCore"]),
    ],
    targets: [
        .target(name: "ShortCutsCore"),
        .executableTarget(name: "ShortCuts", dependencies: ["ShortCutsCore"]),
        // The tests read Fixtures/ and Resources/semantic-model.bin by file path.
        .testTarget(name: "ShortCutsCoreTests", dependencies: ["ShortCutsCore"], exclude: ["Fixtures"]),
    ]
)
