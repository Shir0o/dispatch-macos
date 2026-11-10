// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dispatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Dispatch",
            targets: ["DispatchApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "DispatchApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/DispatchApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DispatchAppTests",
            dependencies: ["DispatchApp"],
            path: "Tests/DispatchAppTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
