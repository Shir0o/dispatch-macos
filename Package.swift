// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevTriage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DevTriage",
            targets: ["DevTriage"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DevTriage",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DevTriageTests",
            dependencies: ["DevTriage"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
