// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CamillaDSP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "camilladsp", targets: ["CamillaDSP"]),
        .executable(name: "CamillaDSPMonitor", targets: ["CamillaDSPMonitor"]),
        .library(name: "CamillaDSPLib", targets: ["CamillaDSPLib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "CamillaDSP",
            dependencies: [
                "CamillaDSPLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/CamillaDSP"
        ),
        .target(
            name: "CamillaDSPLib",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/CamillaDSPLib",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "CamillaDSPMonitor",
            dependencies: [
                "CamillaDSPLib",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/CamillaDSPMonitor"
        ),
        .testTarget(
            name: "CamillaDSPTests",
            dependencies: ["CamillaDSPLib"],
            path: "Tests/CamillaDSPTests"
        ),
    ]
)
