// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DeepSeekMeter",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/EmergeTools/Pow", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekMeter",
            dependencies: [.product(name: "Pow", package: "Pow")],
            path: "Sources/DeepSeekMeter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
