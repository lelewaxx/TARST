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
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(name: "TARSTApp", dependencies: ["TARSTCore"], path: "Sources/TARSTApp"),
        .executableTarget(name: "TARSTCoreCheck", dependencies: ["TARSTCore"], path: "Sources/TARSTCoreCheck"),
        .executableTarget(name: "MiniMaxSmokeTest", dependencies: ["TARSTCore"], path: "Sources/MiniMaxSmokeTest"),
        .executableTarget(name: "MiniMaxStreamSmokeTest", dependencies: ["TARSTCore"], path: "Sources/MiniMaxStreamSmokeTest"),
        .executableTarget(name: "AgentRuntimeBridgeSmokeTest", dependencies: ["TARSTCore"], path: "Sources/AgentRuntimeBridgeSmokeTest"),
        .executableTarget(name: "EndToEndLatencySmokeTest", dependencies: ["TARSTCore"], path: "Sources/EndToEndLatencySmokeTest"),
        .executableTarget(name: "VolcengineTTSSmokeTest", dependencies: ["TARSTCore"], path: "Sources/VolcengineTTSSmokeTest"),
        .executableTarget(name: "VolcengineASRRoundTripSmokeTest", dependencies: ["TARSTCore"], path: "Sources/VolcengineASRRoundTripSmokeTest")
    ],
    swiftLanguageModes: [.v5]
)
