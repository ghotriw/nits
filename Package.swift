// swift-tools-version: 6.0
import PackageDescription

let defaultSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Nits",
    platforms: [.macOS("15.4"), .iOS("18.4")],
    products: [
        .executable(name: "Nits", targets: ["NitsApp"]),
        .library(name: "NitsCore", targets: ["NitsCore"]),
        .library(name: "NitsUI", targets: ["NitsUI"]),
        .library(name: "NitsKit", targets: ["NitsKit"]),
        // Xcode previews only, not for hosts (it holds NitsCore again, next to NitsKit's copy). The preview host loads a
        // dynamic framework with its FFmpeg and libass; with the static products or an app linking them it finds none.
        .library(name: "NitsUIPreviews", type: .dynamic, targets: ["NitsUI"]),
    ],
    targets: [
        // FFmpeg is one module, `CFFmpeg`, on every platform: a C shim over what each platform has. macOS: the system
        // library (the bundled prefix or Homebrew, by pkg-config). iOS: dynamic xcframeworks, built by
        // `scripts/build_dependencies.sh --platform=ios|ios-simulator` and `scripts/make_xcframeworks.sh`.
        .systemLibrary(
            name: "CFFmpegSystem",
            pkgConfig: "libavformat libavcodec libavutil libswresample libswscale",
            providers: [
                .brew(["ffmpeg"]),
                .apt(["libavformat-dev", "libavcodec-dev", "libavutil-dev", "libswresample-dev", "libswscale-dev"]),
            ]
        ),
        // Built and published only by the "Build and Release iOS Dependencies" workflow (build_dependencies.sh +
        // make_xcframeworks.sh --zip) as the pre-release deps-ios-v<DEPS_IOS_VERSION>; the checksums are from the
        // workflow's report. Change with DEPS_IOS_VERSION in scripts/deps_config.sh. (A local path would break package
        // resolution on a checkout without the frameworks.)
        .binaryTarget(
            name: "libavformat",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libavformat.xcframework.zip",
            checksum: "871d193c28ddd5943144e213ae94ba801f86bf8341cfd1a9f04e6c95f372ca9e"
        ),
        .binaryTarget(
            name: "libavcodec",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libavcodec.xcframework.zip",
            checksum: "ca8423dc9069035e07175b0c834e412f3174b2c74d8766e78345deacb12a8f36"
        ),
        .binaryTarget(
            name: "libavutil",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libavutil.xcframework.zip",
            checksum: "13b62c43f56dbcf434b7c84c9eceadbb918fd6ee8a5bf9958847e6c68c011d1b"
        ),
        .binaryTarget(
            name: "libswresample",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libswresample.xcframework.zip",
            checksum: "924f097266b6cd080271d1d3ca0cf4c2a57822161954221cdb6708b7fe6e9a1c"
        ),
        .binaryTarget(
            name: "libswscale",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libswscale.xcframework.zip",
            checksum: "4eb1e6a76e0bd8849bf2687018aa0dad27f78b14fe97223b8cc3bd468bd366fc"
        ),
        .binaryTarget(
            name: "libdav1d",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libdav1d.xcframework.zip",
            checksum: "a99ba6b573c041e05ea23901ebbe08eecb90e3948ddaedee12f4450309436ac7"
        ),
        .target(
            name: "CFFmpeg",
            dependencies: [
                .target(name: "CFFmpegSystem", condition: .when(platforms: [.macOS])),
                .target(name: "libavformat", condition: .when(platforms: [.iOS])),
                .target(name: "libavcodec", condition: .when(platforms: [.iOS])),
                .target(name: "libavutil", condition: .when(platforms: [.iOS])),
                .target(name: "libswresample", condition: .when(platforms: [.iOS])),
                .target(name: "libswscale", condition: .when(platforms: [.iOS])),
                .target(name: "libdav1d", condition: .when(platforms: [.iOS])),
            ]
        ),
        .systemLibrary(
            name: "CLibass",
            pkgConfig: "libass",
            providers: [
                .brew(["libass"]),
                .apt(["libass-dev"]),
            ]
        ),
        // Hot loops that must run optimized in Debug too, kept apart so the rest of NitsCore builds -Onone.
        .target(
            name: "NitsKernels",
            swiftSettings: defaultSwiftSettings + [
                // Software YUV->NV12/P010 conversion (FFmpegVideoDecoder) is hand-SIMD that only
                // vectorizes under -O. Debug (-Onone) makes 10-bit conversion ~40x slower, so 1080p+
                // 10-bit AV1 playback lags and desyncs from audio. Release is unaffected.
                .unsafeFlags(["-O"], .when(configuration: .debug))
            ]
        ),
        // HTTP adaptive streaming client (HLS and DASH): playlists and manifests, segment loading, lanes, adaptive
        // bitrate. Knows nothing of NitsCore; its API is `package`, and only NitsCore (and tests) import it.
        .target(
            name: "NitsStreaming",
            dependencies: ["CFFmpeg"],
            swiftSettings: defaultSwiftSettings
        ),
        .target(
            name: "NitsCore",
            dependencies: [
                "CFFmpeg", .target(name: "CLibass", condition: .when(platforms: [.macOS])), "NitsKernels",
                "NitsStreaming",
            ],
            resources: [
                .process("Video/HDRToneMapping.metal"),
                .process("Video/BT2390ToneMapping.metal"),
                .process("Video/DisplayGamutFit.metal"),
                .process("Video/Deinterlace.metal"),
            ],
            swiftSettings: defaultSwiftSettings
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
        // Wait helpers, in-memory stores and the engine factory shared by the test targets; public API only.
        .target(
            name: "NitsTestSupport",
            dependencies: ["NitsCore"],
            path: "Tests/NitsTestSupport",
            swiftSettings: defaultSwiftSettings
        ),
        // The client on its own: parsers, the timeline, adaptive bitrate. Tests that serve media over HTTP or play it stay in
        // NitsCoreTests, which has the servers and the synthetic media.
        .testTarget(
            name: "NitsStreamingTests",
            dependencies: ["NitsStreaming"],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "NitsCoreTests",
            dependencies: ["NitsCore", "NitsStreaming", "NitsKernels", "NitsTestSupport"],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "NitsKitTests",
            dependencies: ["NitsKit", "NitsUI", "NitsTestSupport"],
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
