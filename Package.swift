// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/EmergeTools/Pow", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "TokenMeter",
            dependencies: [.product(name: "Pow", package: "Pow")],
            path: "Sources/TokenMeter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TokenMeterTests",
            dependencies: ["TokenMeter"],
            path: "Tests/TokenMeterTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
