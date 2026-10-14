// swift-tools-version: 6.0
import PackageDescription

let defaultSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Nits",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nits", targets: ["NitsApp"]),
        .library(name: "NitsCore", targets: ["NitsCore"]),
        .library(name: "NitsUI", targets: ["NitsUI"]),
        .library(name: "NitsKit", targets: ["NitsKit"]),
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat libavcodec libavutil libswresample libswscale",
            providers: [
                .brew(["ffmpeg"]),
                .apt(["libavformat-dev", "libavcodec-dev", "libavutil-dev", "libswresample-dev", "libswscale-dev"]),
            ]
        ),
        .target(
            name: "NitsCore",
            dependencies: ["CFFmpeg"],
            resources: [
                .process("Video/HDRToneMapping.metal"),
                .process("Video/BT2390ToneMapping.metal"),
            ],
            swiftSettings: defaultSwiftSettings + [
                // Software YUV->NV12/P010 conversion (FFmpegVideoDecoder) is hand-SIMD that only
                // vectorizes under -O. Debug (-Onone) makes 10-bit conversion ~40x slower, so 1080p+
                // 10-bit AV1 playback lags and desyncs from audio. Optimize NitsCore even in Debug so
                // software playback stays usable while developing (release is unaffected).
                .unsafeFlags(["-O"], .when(configuration: .debug))
            ]
        ),
        .target(
            name: "NitsUI",
            dependencies: ["NitsCore"],
            resources: [
                .process("Shaders/SubtitleShaders.metal")
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .target(
            name: "NitsKit",
            dependencies: ["NitsCore", "NitsUI"],
            swiftSettings: defaultSwiftSettings
        ),
        .executableTarget(
            name: "NitsApp",
            dependencies: ["NitsCore", "NitsUI", "NitsKit"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "NitsCoreTests",
            dependencies: ["NitsCore"],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "NitsKitTests",
            dependencies: ["NitsKit", "NitsUI"],
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
