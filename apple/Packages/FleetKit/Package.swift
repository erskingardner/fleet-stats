// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "FleetKit",
            targets: ["FleetKit"]
        )
    ],
    targets: [
        .target(
            name: "FleetKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FleetKitTests",
            dependencies: ["FleetKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
