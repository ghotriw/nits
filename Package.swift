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
        // The resolver of video sites' pages over yt-dlp, which a `YTDLPRunner` runs (NitsKit: a process; an iOS host: its own).
        .library(name: "NitsYTDLP", targets: ["NitsYTDLP"]),
        // The iOS player screen and its lifecycle owner (v1: bare controls); empty on macOS, as SwiftPM builds every target there.
        .library(name: "NitsTouch", targets: ["NitsTouch"]),
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
            checksum: "59ef6855973cdf0f863b7c79fa0baeda598a0f35c400deb6a9b9dfc38751c865"
        ),
        .binaryTarget(
            name: "libavcodec",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libavcodec.xcframework.zip",
            checksum: "a8c62da8659e181eacaaeee34b9bc2ef610b446a92ecc5e3acaaa2264a785f45"
        ),
        .binaryTarget(
            name: "libavutil",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libavutil.xcframework.zip",
            checksum: "52b1e9191926ef12377c060d5d5e8baac4963ca307cfee8011022b22e84c0c4e"
        ),
        .binaryTarget(
            name: "libswresample",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libswresample.xcframework.zip",
            checksum: "28409a355e818299ba4634da63936d07c0909e8942d5c6e84101578b21b9920d"
        ),
        .binaryTarget(
            name: "libswscale",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libswscale.xcframework.zip",
            checksum: "af034ba26c91b7c271925c5567f19fac7a639c12930d558c411f06b4b3314082"
        ),
        .binaryTarget(
            name: "libdav1d",
            url: "https://github.com/ghotriw/nits/releases/download/deps-ios-v1.0.0/libdav1d.xcframework.zip",
            checksum: "049e46cfa1501034bf7e1edf8997b97f768ade4ecde4f5514c7906160ddb8bd9"
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
        // Plays the pages of video sites (YouTube, …) from what yt-dlp says of them. Imports NitsCore only, builds for macOS
        // and iOS: it never runs yt-dlp itself, a `YTDLPRunner` does.
        .target(
            name: "NitsYTDLP",
            dependencies: ["NitsCore"],
            swiftSettings: defaultSwiftSettings
        ),
        .target(
            name: "NitsKit",
            dependencies: ["NitsCore", "NitsUI", "NitsYTDLP"],
            swiftSettings: defaultSwiftSettings
        ),
        // The iOS player screen: SwiftUI over `NitsCore`'s engine, every file in `#if os(iOS)` (SwiftPM has no per-platform
        // targets, so macOS builds it empty). Imports NitsCore only.
        .target(
            name: "NitsTouch",
            dependencies: ["NitsCore"],
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
        // Run on the iOS Simulator (macOS builds it empty); engine tests that play media stay in NitsCoreTests.
        .testTarget(
            name: "NitsTouchTests",
            dependencies: ["NitsTouch", "NitsCore"],
            swiftSettings: defaultSwiftSettings
        ),
        // The resolver over a runner that is no process, and what it reads of yt-dlp's answers.
        .testTarget(
            name: "NitsYTDLPTests",
            dependencies: ["NitsYTDLP", "NitsCore", "NitsTestSupport"],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "NitsKitTests",
            dependencies: ["NitsKit", "NitsUI", "NitsYTDLP", "NitsTestSupport"],
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
