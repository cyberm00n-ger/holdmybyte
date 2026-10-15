// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "holdmybyte",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "holdmybyte", targets: ["HoldMyByteApp"]),
        .executable(name: "hmb", targets: ["hmb"]),
        .executable(name: "hmb-snapshot", targets: ["HMBSnapshot"]),
    ],
    targets: [
        .binaryTarget(name: "HMBCodecsBinary", path: "Vendor/xcframeworks/HMBCodecs.xcframework"),
        .target(
            name: "CHMBCodecs",
            dependencies: ["HMBCodecsBinary"],
            cxxSettings: [
                .headerSearchPath("vendor-include"),
                .define("JXL_STATIC_DEFINE"), .define("JXL_THREADS_STATIC_DEFINE"), .define("JXL_CMS_STATIC_DEFINE"),
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(name: "HMBModel"),
        .target(name: "HMBEngine", dependencies: ["HMBModel", "CHMBCodecs"]),
        .target(name: "HMBStore", dependencies: ["HMBModel"]),
        .target(name: "HMBFixtures", dependencies: ["HMBModel"]),
        .target(name: "HMBUI", dependencies: ["HMBModel", "HMBFixtures"]),
        .executableTarget(name: "HoldMyByteApp", dependencies: ["HMBUI", "HMBEngine", "HMBStore", "HMBModel"]),
        .target(name: "HMBBench", dependencies: ["HMBEngine", "HMBModel"]),
        .executableTarget(name: "hmb", dependencies: ["HMBBench", "HMBEngine", "HMBModel"]),
        .executableTarget(name: "HMBSnapshot", dependencies: ["HMBUI", "HMBFixtures", "HMBModel"]),
        .testTarget(name: "HMBModelTests", dependencies: ["HMBModel"]),
        .testTarget(name: "HMBEngineTests", dependencies: ["HMBEngine", "HMBModel", "HMBFixtures"]),
        .testTarget(name: "HMBStoreTests", dependencies: ["HMBStore", "HMBModel", "HMBFixtures"]),
        .testTarget(name: "HMBUITests", dependencies: ["HMBUI", "HMBModel", "HMBFixtures"]),
        .testTarget(name: "HMBBenchTests", dependencies: ["HMBBench", "HMBModel"]),
    ],
    cxxLanguageStandard: .cxx17
)
