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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DispatchApp",
            dependencies: [],
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
