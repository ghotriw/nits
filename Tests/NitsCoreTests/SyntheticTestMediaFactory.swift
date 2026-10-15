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
        /// WMV2 video (3s) encoded with wmv2 (640x360 @ 24fps) with WMAv2 audio in ASF container
        case wmv2SDR
        /// VP9 video (3s) encoded with libvpx-vp9 (640x360 @ 24fps) 8-bit SDR in WebM container
        case vp9SDR
        /// VP9 video (3s) encoded with libvpx-vp9 (640x360 @ 24fps) 10-bit HDR (BT.2020 / PQ) in WebM container
        case vp910BitHDR
        /// VP9 profile 2 video (3s, 640x360 @ 24fps) 10-bit SDR (BT.709) in MP4 (`vpcC` from the container)
        case vp910BitSDRMP4
        /// Anamorphic H.264 (3s): 720x480 storage with 32:27 sample aspect ratio (16:9 display)
        case anamorphicH264
        /// HEVC 10-bit HLG video (3s) with BT.2020 primaries in MP4
        case hevc10BitHLG
        /// H.264 + AAC MKV (20s, keyframe every second) with the chapters in `chapterMetadata`
        case chaptersMKV
        /// Same as `chaptersMKV` in MP4 (QuickTime chapter track + Nero `chpl`)
        case chaptersMP4

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
            case .wmv2SDR:
                return "synth_wmv2_sdr.wmv"
            case .vp9SDR:
                return "synth_vp9_sdr.webm"
            case .vp910BitHDR:
                return "synth_vp9_10bit_hdr.webm"
            case .vp910BitSDRMP4:
                return "synth_vp9_10bit_sdr.mp4"
            case .anamorphicH264:
                return "synth_anamorphic_h264.mp4"
            case .hevc10BitHLG:
                return "synth_hevc_10bit_hlg.mp4"
            case .chaptersMKV:
                return "synth_chapters_h264.mkv"
            case .chaptersMP4:
                return "synth_chapters_h264.mp4"
            }
        }
    }

    /// Chapters muxed into the chapter presets: (start, end, title) in seconds; the third has no title.
    public static let chapterMarkers: [(start: Double, end: Double, title: String?)] = [
        (0, 4, "Opening"),
        (4, 9, "Глава вторая"),
        (9, 14, nil),
        (14, 20, "Finale"),
    ]

    /// `chapterMarkers` as an FFMETADATA1 document, fed to FFmpeg with `-map_chapters`.
    static var chapterMetadata: String {
        var lines = [";FFMETADATA1"]
        for marker in chapterMarkers {
            lines += [
                "[CHAPTER]", "TIMEBASE=1/1000", "START=\(Int(marker.start * 1000))", "END=\(Int(marker.end * 1000))",
            ]
            if let title = marker.title {
                lines.append("title=\(title)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

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
    ///
    /// Tests run in parallel and share the cache, so FFmpeg writes to a private partial file that is
    /// renamed into place only once complete: a reader never sees a half-written file (an MP4's
    /// `moov` atom is written last). Concurrent callers may both generate; the last rename wins.
    public static func ensureMedia(preset: Preset = .multiTrackH264) -> String? {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NitsSyntheticMedia")
        let targetPath = tmpDir.appendingPathComponent(preset.filename).path

        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: targetPath) {
            return targetPath
        }

        guard let ffmpeg = ffmpegBinaryPath() else {
            print("[SyntheticTestMediaFactory] FFmpeg not found, cannot synthesize \(preset.rawValue)")
            return nil
        }

        // Keeps the preset's extension so FFmpeg still infers the container from it.
        func partialPath() -> String {
            tmpDir.appendingPathComponent(".partial-\(UUID().uuidString)-\(preset.filename)").path
        }

        // Private per run for the same reason as the partial output file.
        let metadataPath = tmpDir.appendingPathComponent(".partial-\(UUID().uuidString).ffmeta").path
        defer { try? FileManager.default.removeItem(atPath: metadataPath) }
        if preset == .chaptersMKV || preset == .chaptersMP4 {
            guard FileManager.default.createFile(atPath: metadataPath, contents: Data(chapterMetadata.utf8)) else {
                print("[SyntheticTestMediaFactory] Failed to write chapter metadata for \(preset.rawValue)")
                return nil
            }
        }

        let encodedPath = partialPath()
        defer { try? FileManager.default.removeItem(atPath: encodedPath) }
        let encodeArguments = arguments(for: preset, outputPath: encodedPath, metadataPath: metadataPath)
        guard runFFmpeg(ffmpeg, arguments: encodeArguments, preset: preset) else {
            return nil
        }

        var readyPath = encodedPath
        // For VP9 10-bit HDR WebM, libvpx-vp9 ignores container color metadata during initial encoding pass.
        // A secondary remux pass copies the bitstream and correctly injects WebM Matroska Color elements.
        let remuxedPath = partialPath()
        defer { try? FileManager.default.removeItem(atPath: remuxedPath) }
        if preset == .vp910BitHDR {
            let remuxArguments = [
                "-y", "-i", encodedPath,
                "-c", "copy",
                "-color_primaries:v", "bt2020",
                "-color_trc:v", "smpte2084",
                "-colorspace:v", "bt2020nc",
                remuxedPath,
            ]
            guard runFFmpeg(ffmpeg, arguments: remuxArguments, preset: preset) else { return nil }
            readyPath = remuxedPath
        }

        // rename(2) atomically replaces any copy another test published meanwhile.
        guard rename(readyPath, targetPath) == 0 else {
            print("[SyntheticTestMediaFactory] Failed to publish \(preset.rawValue): errno \(errno)")
            return nil
        }
        return targetPath
    }

    /// Runs FFmpeg to completion. stderr is drained while the process runs (a full pipe would block it)
    /// and only errors are logged, so the output stays small.
    private static func runFFmpeg(_ ffmpeg: String, arguments: [String], preset: Preset) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostats", "-loglevel", "error"] + arguments
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            print("[SyntheticTestMediaFactory] Failed to launch FFmpeg: \(error)")
            return false
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            print(
                "[SyntheticTestMediaFactory] FFmpeg failed for \(preset.rawValue) with exit code \(process.terminationStatus): \(errText.split(separator: "\n").joined(separator: " | "))"
            )
            return false
        }
        return true
    }

    private static func arguments(for preset: Preset, outputPath: String, metadataPath: String) -> [String] {
        switch preset {
        case .chaptersMKV, .chaptersMP4:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=20",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=20",
                "-f", "ffmetadata", "-i", metadataPath,
                "-map", "0:v", "-map", "1:a", "-map_chapters", "2",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24",
                "-c:a", "aac", "-b:a", "128k",
                outputPath,
            ]
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

        case .wmv2SDR:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "wmv2", "-b:v", "2000k",
                "-c:a", "wmav2", "-b:a", "128k",
                outputPath,
            ]

        case .vp9SDR:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-crf", "30", "-b:v", "0",
                "-c:a", "libopus", "-b:a", "128k",
                outputPath,
            ]

        case .vp910BitHDR:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p10le", "-crf", "30", "-b:v", "0",
                "-color_primaries", "bt2020",
                "-color_trc", "smpte2084",
                "-colorspace", "bt2020nc",
                "-c:a", "libopus", "-b:a", "128k",
                outputPath,
            ]

        case .vp910BitSDRMP4:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p10le", "-crf", "30", "-b:v", "0",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                outputPath,
            ]

        case .anamorphicH264:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=24:duration=3",
                "-vf", "setsar=32/27",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                outputPath,
            ]

        case .hevc10BitHLG:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020",
                "-color_trc", "arib-std-b67",
                "-colorspace", "bt2020nc",
                "-x265-params", "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=error",
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
