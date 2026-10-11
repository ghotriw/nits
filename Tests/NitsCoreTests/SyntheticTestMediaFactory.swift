import Foundation

/// Provides automated, deterministic synthetic test media generation via FFmpeg.
/// Generates test assets dynamically into the temporary directory if not already cached.
public enum SyntheticTestMediaFactory {

    public enum Preset: String, CaseIterable, Sendable {
        /// Standard multi-track video: H.264 video with GOP=24, AC3 5.1 Surround audio, and AAC Stereo audio (30 seconds)
        case multiTrackH264
        /// Audio-only multi-channel FLAC (15 seconds)
        case audioOnlyFLAC
        /// HEVC 10-bit HDR video with BT.2020 color primaries and PQ transfer function (10 seconds)
        case hevc10BitHDR
        /// 4K HEVC 10-bit HDR10 MKV with 5 SRT subtitle tracks, first forced (3 seconds)
        case uhdHDRSubtitles
        /// H.264 video with AC3 5.1 (fltp), DTS 5.1 and 16-bit FLAC 5.1 (s16) audio tracks (10 seconds)
        case exoticAudioTracks
        /// Audio codec/layout matrix with a distinct tone per channel (6 seconds): E-AC3 5.1, Opus 5.1, AAC 7.1,
        /// MP3 44.1kHz stereo, AC3 44.1kHz stereo (resampling), TrueHD 5.1, PCM 24-bit 5.1
        case audioCodecMatrix
        /// H.264 video (60s) with strictly spaced keyframes every 5.0 seconds (GOP=120 @ 24fps, no scenecut)
        case wideGOPH264
        /// AV1 video (3s) encoded with libsvtav1 (640x360 @ 24fps) with AAC audio
        case av1SDR

        public var filename: String {
            switch self {
            case .multiTrackH264:
                return "synth_multitrack_h264_51_stereo.mkv"
            case .audioOnlyFLAC:
                return "synth_audio_flac_51.flac"
            case .hevc10BitHDR:
                return "synth_hevc_10bit_hdr.mp4"
            case .audioCodecMatrix:
                return "synth_audio_codec_matrix.mkv"
            case .exoticAudioTracks:
                return "synth_exotic_audio_tracks.mkv"
            case .uhdHDRSubtitles:
                return "synth_uhd_hdr_5subs.mkv"
            case .wideGOPH264:
                return "synth_wide_gop_h264_5s.mp4"
            case .av1SDR:
                return "synth_av1_sdr.mkv"
            }
        }
    }

    private static let lock = NSLock()

    /// Resolves the absolute path to `ffmpeg` binary on the machine.
    public static func ffmpegBinaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Try 'which ffmpeg'
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !out.isEmpty, FileManager.default.isExecutableFile(atPath: out)
        {
            return out
        }
        return nil
    }

    /// Ensures that the specified media preset is generated and available on disk.
    /// Returns the absolute path to the ready file, or `nil` if FFmpeg is unavailable.
    public static func ensureMedia(preset: Preset = .multiTrackH264) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NitsSyntheticMedia")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let targetURL = tmpDir.appendingPathComponent(preset.filename)
        let targetPath = targetURL.path

        // Check if cached file already exists and has valid size (> 4KB)
        if FileManager.default.fileExists(atPath: targetPath),
            let attr = try? FileManager.default.attributesOfItem(atPath: targetPath),
            let size = attr[.size] as? UInt64, size > 4096
        {
            return targetPath
        }

        guard let ffmpeg = ffmpegBinaryPath() else {
            print("[SyntheticTestMediaFactory] FFmpeg not found, cannot synthesize \(preset.rawValue)")
            return nil
        }

        let arguments = arguments(for: preset, outputPath: targetPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: targetPath) {
                return targetPath
            } else {
                let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                print(
                    "[SyntheticTestMediaFactory] FFmpeg failed with exit code \(process.terminationStatus): \(errText.split(separator: "\n").filter { $0.contains("rror") || $0.contains("nvalid") || $0.contains("not ") || $0.contains("Unable") }.joined(separator: " | "))"
                )
                return nil
            }
        } catch {
            print("[SyntheticTestMediaFactory] Failed to launch FFmpeg: \(error)")
            return nil
        }
    }

    private static func arguments(for preset: Preset, outputPath: String) -> [String] {
        switch preset {
        case .multiTrackH264:
            // 30 seconds H.264 (640x360 @ 24fps, GOP=24 with B-frames)
            // Track 1: 5.1 Surround AC3 (384k)
            // Track 2: 2.0 Stereo AAC (128k)
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=30",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=30",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=30",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24",
                "-filter_complex", "[1:a]channelmap=0|0|0|0|0|0:5.1[a1];[2:a]channelmap=0|0:stereo[a2]",
                "-map", "0:v", "-map", "[a1]", "-map", "[a2]",
                "-c:a:0", "ac3", "-b:a:0", "384k", "-metadata:s:a:0", "title=Surround 5.1", "-metadata:s:a:0",
                "language=eng",
                "-c:a:1", "aac", "-b:a:1", "128k", "-metadata:s:a:1", "title=Stereo 2.0", "-metadata:s:a:1",
                "language=ukr",
                outputPath,
            ]

        case .audioOnlyFLAC:
            // 15 seconds 5.1 Surround FLAC
            return [
                "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=15",
                "-filter_complex", "[0:a]channelmap=0|0|0|0|0|0:5.1[a]",
                "-map", "[a]",
                "-c:a", "flac",
                outputPath,
            ]

        case .audioCodecMatrix:
            return audioCodecMatrixArguments(outputPath: outputPath)

        case .exoticAudioTracks:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=660:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=10",
                "-filter_complex",
                "[1:a]channelmap=0|0|0|0|0|0:5.1[a1];[2:a]channelmap=0|0|0|0|0|0:5.1[a2];[3:a]aformat=sample_fmts=s16:sample_rates=48000,channelmap=0|0|0|0|0|0:5.1[a3]",
                "-map", "0:v", "-map", "[a1]", "-map", "[a2]", "-map", "[a3]",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24",
                "-c:a:0", "ac3", "-b:a:0", "384k", "-metadata:s:a:0", "language=ukr",
                "-c:a:1", "dts", "-strict", "-2", "-b:a:1", "768k", "-metadata:s:a:1", "language=eng",
                "-c:a:2", "flac", "-sample_fmt:a:2", "s16", "-metadata:s:a:2", "language=eng",
                outputPath,
            ]

        case .uhdHDRSubtitles:
            // 3 seconds 4K HEVC Main10 HDR10 + AAC + 5 SRT subtitle tracks (first one forced)
            let dir = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
            var args: [String] = [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=3840x2160:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            ]
            for i in 0..<5 {
                let srt = dir.appendingPathComponent("synth_sub_\(i).srt")
                let text = "1\n00:00:00,000 --> 00:00:02,000\nSubtitle \(i)\n"
                try? text.write(to: srt, atomically: true, encoding: .utf8)
                args += ["-i", srt.path]
            }
            args += ["-map", "0:v", "-map", "1:a"]
            for i in 0..<5 { args += ["-map", "\(i + 2):0"] }
            args += [
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast",
                "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
                "-x265-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                "-bsf:v", "hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9",
                "-color_range", "tv",
                "-c:a", "aac", "-b:a", "128k",
                "-c:s", "srt",
                "-metadata:s:s:0", "title=Forced", "-disposition:s:0", "forced",
                outputPath,
            ]
            return args

        case .hevc10BitHDR:
            // 10 seconds 1080p HEVC Main10, BT.2020 primaries, PQ transfer (HDR10)
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020",
                "-color_trc", "smpte2084",
                "-colorspace", "bt2020nc",
                "-x265-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                "-c:a", "aac", "-b:a", "192k",
                outputPath,
            ]

        case .wideGOPH264:
            // 60 seconds H.264 (640x360 @ 24fps)
            // Strictly spaced keyframes every 5.0 seconds: GOP=120, keyint_min=120, sc_threshold=0 (no scenecut)
            // AAC stereo audio
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=60",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=60",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-g", "120", "-keyint_min", "120", "-sc_threshold", "0",
                "-c:a", "aac", "-b:a", "128k",
                outputPath,
            ]

        case .av1SDR:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "libsvtav1", "-preset", "10", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k",
                outputPath,
            ]
        }
    }

    // MARK: - Audio codec matrix

    /// One entry of the codec matrix: encoder + layout + per-channel tone generation.
    struct AudioMatrixTrack: Sendable {
        let name: String
        let channels: Int
        let layout: String
        let sampleRate: Int
        let encoderArgs: [String]
    }

    static let audioMatrixTracks: [AudioMatrixTrack] = [
        .init(
            name: "eac3_51", channels: 6, layout: "5.1", sampleRate: 48000,
            encoderArgs: ["-c:a", "eac3", "-b:a", "448k"]),
        .init(
            name: "opus_51", channels: 6, layout: "5.1", sampleRate: 48000,
            encoderArgs: ["-c:a", "libopus", "-b:a", "384k", "-mapping_family", "1"]),
        .init(
            name: "aac_71", channels: 8, layout: "7.1", sampleRate: 48000, encoderArgs: ["-c:a", "aac", "-b:a", "512k"]),
        .init(
            name: "mp3_441_stereo", channels: 2, layout: "stereo", sampleRate: 44100,
            encoderArgs: ["-c:a", "libmp3lame", "-b:a", "192k"]),
        .init(
            name: "ac3_441_stereo", channels: 2, layout: "stereo", sampleRate: 44100,
            encoderArgs: ["-c:a", "ac3", "-b:a", "192k"]),
        .init(
            name: "truehd_51", channels: 6, layout: "5.1", sampleRate: 48000,
            encoderArgs: ["-c:a", "truehd", "-strict", "-2"]),
        .init(name: "pcm24_51", channels: 6, layout: "5.1", sampleRate: 48000, encoderArgs: ["-c:a", "pcm_s24le"]),
    ]

    private static func audioCodecMatrixArguments(outputPath: String) -> [String] {
        var args: [String] = ["-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=6"]
        var filters: [String] = []
        var nextInput = 1  // input 0 is the video
        for (t, track) in audioMatrixTracks.enumerated() {
            // Distinct tone per channel so channel swaps/mixups are detectable (LFE gets 60 Hz: codecs low-pass it).
            var inputs = ""
            for c in 0..<track.channels {
                args += [
                    "-f", "lavfi", "-i",
                    "sine=frequency=\(track.channels >= 6 && c == 3 ? 60 : 300 + 130 * c):sample_rate=\(track.sampleRate):duration=6",
                ]
                inputs += "[\(nextInput):a]"
                nextInput += 1
            }
            let map = (0..<track.channels).map(String.init).joined(separator: "|")
            filters.append("\(inputs)amerge=inputs=\(track.channels),channelmap=\(map):\(track.layout)[a\(t)]")
        }
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "0:v"]
        for t in 0..<audioMatrixTracks.count { args += ["-map", "[a\(t)]"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-g", "24"]
        for (t, track) in audioMatrixTracks.enumerated() {
            // Option names (starting with '-') need a per-stream specifier.
            for a in track.encoderArgs {
                if !(a.hasPrefix("-") && (a.dropFirst().first?.isLetter ?? false)) {
                    args.append(a)
                } else if a.hasSuffix(":a") {
                    args.append("\(a):\(t)")
                } else {
                    args.append("\(a):a:\(t)")
                }
            }
            args += ["-metadata:s:a:\(t)", "title=\(track.name)"]
        }
        args.append(outputPath)
        return args
    }
}
