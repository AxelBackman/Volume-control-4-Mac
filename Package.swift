// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "VolumeMixer", targets: ["VolumeMixer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "VolumeMixerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VolumeMixer",
            dependencies: [
                "VolumeMixerCore",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["VolumeMixerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
