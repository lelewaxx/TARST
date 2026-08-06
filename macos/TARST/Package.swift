// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TARST",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TARST", targets: ["TARSTApp"])
    ],
    targets: [
        .target(
            name: "TARSTCore",
            path: "Sources/TARST",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(name: "TARSTApp", dependencies: ["TARSTCore"], path: "Sources/TARSTApp"),
        .executableTarget(name: "TARSTCoreCheck", dependencies: ["TARSTCore"], path: "Sources/TARSTCoreCheck")
    ],
    swiftLanguageModes: [.v5]
)
