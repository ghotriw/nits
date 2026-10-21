import Foundation
import os

/// Provides automated, deterministic synthetic test media generation via FFmpeg.
/// Generates test assets dynamically into the temporary directory if not already cached.
public enum SyntheticTestMediaFactory {

    public enum Preset: String, CaseIterable, Sendable {
        /// Standard multi-track video: H.264 video with GOP=24, AC3 5.1 Surround audio, and AAC Stereo audio (30 seconds)
        case multiTrackH264
        /// H.264 at 60 fps with stereo AAC (20 seconds): a frame queue of 25–40 frames holds under 0.7 s
        case h264HFR60
        /// H.264 without an audio track (20 seconds)
        case videoOnlyH264
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
        /// MPEG-4 Part 2 / Xvid (5s, 640x360 @ 24fps, 2 B-frames, keyframe every second) with MP3 audio in AVI:
        /// AVI carries only decode timestamps, so presentation order comes from the decoder
        case mpeg4XvidAVI
        /// Microsoft MPEG-4 v3 / DivX 3 (3s, 640x360 @ 24fps) with MP2 audio in AVI
        case msmpeg4v3AVI
        /// H.263 baseline (3s, CIF 352x288 @ 15fps) with AAC audio in 3GP
        case h263CIF3GP
        /// H.263+ (3s, 640x360 @ 24fps) in MKV
        case h263pMKV
        /// DVD-style MPEG-2 (4s, 720x480 anamorphic 16:9 @ 29.97fps, GOP 15, 2 B-frames) with AC-3 audio in VOB
        case mpeg2DVDVOB
        /// Interlaced (top field first) PAL MPEG-2 (4s, 720x576 4:3 @ 25fps) with MP2 audio in MPEG-TS. Woven from
        /// 50p, so the two fields of a frame show different moments and moving areas comb like camera footage.
        case mpeg2InterlacedTS
        /// VCD-style MPEG-1 (4s, 352x240 @ 29.97fps, 2 B-frames) with MP2 audio in MPEG-PS
        case mpeg1MPG
        /// Sorenson Spark / FLV1 (4s, 320x240 @ 25fps) with MP3 audio in FLV
        case flvSpark
        /// VP8 (4s, 640x360 @ 30fps, libvpx defaults incl. hidden alt-ref frames) with Vorbis audio in WebM
        case vp8WebM
        /// RealVideo 1.0 (4s, 320x240 @ 15fps) with RealAudio 1.0 (14.4K, 8 kHz mono) in RealMedia
        case rv10RM
        /// RealVideo 2.0 (4s, CIF 352x288 @ 25fps) in RealMedia
        case rv20RM
        /// Motion JPEG 4:2:2 full range (3s, 640x360 @ 25fps) with PCM audio in AVI, as early digital cameras wrote it
        case mjpegAVI
        /// NTSC DV 4:1:1 (3s, 720x480 4:3 @ 29.97fps) with 48 kHz PCM in a raw DV stream
        case dvNTSC
        /// Cinepak, decoded as RGB (3s, 320x240 @ 15fps) in QuickTime
        case cinepakMOV
        /// Apple ProRes 422 10-bit 4:2:2 (3s, 640x360 @ 24fps) in QuickTime
        case proresMOV
        /// Interlaced H.264 (MBAFF, top field first) as DVB broadcasts it (3s, 720x576 4:3 @ 25i from 50p, so moving
        /// areas comb) with MP2 audio in MPEG-TS. VideoToolbox can't decode field-coded H.264.
        case h264InterlacedTS
        /// Interlaced MPEG-2 (2s, 720x576 @ 25i, top field first) of a still picture whose rows alternate between
        /// light and dark, one row each: every field is uniform and the frame looks combed throughout, yet nothing
        /// moves, so the fields show the same moment. Video only, in MPEG-TS.
        case interlacedStaticDetailTS
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
        /// HEVC MKV (3s, 320x240, 25 fps) as a cut that ignores keyframes leaves it: an `hvcC` without parameter sets
        /// (they come in-band with every keyframe) and video that starts 8 s after its PCM audio, whose ~6000
        /// packets come first
        case hevcInBandParameterSetsMKV
        /// H.264 + AAC MKV (20s, keyframe every second) with the chapters in `chapterMetadata`
        case chaptersMKV
        /// Same as `chaptersMKV` in MP4 (QuickTime chapter track + Nero `chpl`)
        case chaptersMP4
        /// H.264 MKV (6s, 320x240) with a PGS track made by `pgsStream`: a bar shown 0-1.5 s (cleared by an empty set)
        /// and one from 2.5 s that is never cleared
        case pgsSubtitlesMKV
        /// H.264 MKV (6s, 640x360) with the ASS track `AssSubtitleTests.script`: "Hello" 0-2 s and a red box from 3 s
        case assSubtitlesMKV
        /// H.264 MKV (4s, 640x360, 60 fps) with the ASS track `AssSubtitleTests.fadeScript`: "Hello" fading in over 0.5-2 s
        case assFadeSubtitlesMKV
        /// H.264 MPEG-TS (6s, 320x240) with a DVB track FFmpeg converts from `pgsStream`: a timeline that starts at
        /// about 1.48 s (rebased to 0), the bar at 0 s cleared at about 5.13 s (the conversion drops the set at 2.5 s),
        /// and no index
        case dvbSubtitlesTS
        /// H.264 MPEG-TS (6s, 320x240, 30 fps, no B-frames) with `captionScript` as CEA-608 CC1 in SEI messages
        /// (`captionSEI`), field 2 null padding and a CEA-708 triplet beside it in every picture
        case captionsH264TS
        /// `captionsH264TS` remuxed into Matroska: length-prefixed units, no decode timestamps
        case captionsH264MKV
        /// H.264 MOV (6s, 320x240) with `captionScript` in a `c608` caption track, made from `captionSCC`
        case captionsC608MOV
        /// `captionsC608MOV` in a fragment a second (`frag_keyframe+empty_moov`): its `moov` lists no sample, and FFmpeg
        /// reads every fragment of a seekable file without a complete `sidx` at opening
        case captionsC608FragmentedMOV

        /// Presets whose picture stream carries closed captions put in by `captionedStream`.
        var hasCaptionSEI: Bool { self == .captionsH264TS || self == .captionsH264MKV }

        public var filename: String {
            switch self {
            case .multiTrackH264:
                return "synth_multitrack_h264_51_stereo.mkv"
            case .h264HFR60:
                return "synth_h264_60fps.mp4"
            case .videoOnlyH264:
                return "synth_h264_video_only.mp4"
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
            case .mpeg4XvidAVI:
                return "synth_mpeg4_xvid_bframes.avi"
            case .msmpeg4v3AVI:
                return "synth_msmpeg4v3.avi"
            case .h263CIF3GP:
                return "synth_h263_cif.3gp"
            case .h263pMKV:
                return "synth_h263p.mkv"
            case .mpeg2DVDVOB:
                return "synth_mpeg2_dvd.vob"
            case .mpeg2InterlacedTS:
                return "synth_mpeg2_pal_interlaced_50i.ts"
            case .mpeg1MPG:
                return "synth_mpeg1_vcd.mpg"
            case .flvSpark:
                return "synth_flv1_spark.flv"
            case .vp8WebM:
                return "synth_vp8_vorbis.webm"
            case .rv10RM:
                return "synth_rv10_ra144.rm"
            case .rv20RM:
                return "synth_rv20.rm"
            case .mjpegAVI:
                return "synth_mjpeg_422.avi"
            case .dvNTSC:
                return "synth_dv_ntsc_411.dv"
            case .cinepakMOV:
                return "synth_cinepak_rgb.mov"
            case .proresMOV:
                return "synth_prores_422_10bit.mov"
            case .h264InterlacedTS:
                return "synth_h264_576i.ts"
            case .interlacedStaticDetailTS:
                return "synth_mpeg2_576i_static_stripes.ts"
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
            case .hevcInBandParameterSetsMKV:
                return "synth_hevc_inband_parameter_sets.mkv"
            case .chaptersMKV:
                return "synth_chapters_h264.mkv"
            case .chaptersMP4:
                return "synth_chapters_h264.mp4"
            case .pgsSubtitlesMKV:
                return "synth_pgs_subtitles.mkv"
            case .assSubtitlesMKV:
                return "synth_ass_subtitles.mkv"
            case .assFadeSubtitlesMKV:
                return "synth_ass_fade_subtitles.mkv"
            case .dvbSubtitlesTS:
                return "synth_dvb_subtitles.ts"
            case .captionsH264TS:
                return "synth_captions_h264.ts"
            case .captionsH264MKV:
                return "synth_captions_h264.mkv"
            case .captionsC608FragmentedMOV:
                return "synth_captions_c608_fragmented.mov"
            case .captionsC608MOV:
                return "synth_captions_c608.mov"
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
    /// Tests run in parallel and share the cache. Within a process each preset is generated once: other callers
    /// wait for it instead of running their own encode, which on a 3-core CI runner starved every test for over a
    /// minute. Across processes (the test targets) FFmpeg writes to a private partial file that is renamed into
    /// place only once complete, so a reader never sees a half-written file (an MP4's `moov` atom is written last).
    public static func ensureMedia(preset: Preset = .multiTrackH264) -> String? {
        let gate = generationGates.withLock { gates in
            if let gate = gates[preset] { return gate }
            let gate = DispatchSemaphore(value: 1)
            gates[preset] = gate
            return gate
        }
        gate.wait()
        defer { gate.signal() }
        return generateMedia(preset: preset)
    }

    private static let generationGates = OSAllocatedUnfairLock(initialState: [Preset: DispatchSemaphore]())

    private static func generateMedia(preset: Preset) -> String? {
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
        if preset == .assSubtitlesMKV || preset == .assFadeSubtitlesMKV {
            let script = preset == .assSubtitlesMKV ? AssSubtitleTests.script : AssSubtitleTests.fadeScript
            guard FileManager.default.createFile(atPath: metadataPath, contents: Data(script.utf8))
            else {
                print("[SyntheticTestMediaFactory] Failed to write the ASS script for \(preset.rawValue)")
                return nil
            }
        }
        if preset == .pgsSubtitlesMKV || preset == .dvbSubtitlesTS {
            guard FileManager.default.createFile(atPath: metadataPath, contents: pgsStream) else {
                print("[SyntheticTestMediaFactory] Failed to write the PGS stream for \(preset.rawValue)")
                return nil
            }
        }

        if preset == .captionsC608MOV || preset == .captionsC608FragmentedMOV {
            guard FileManager.default.createFile(atPath: metadataPath, contents: Data(captionSCC.utf8)) else {
                print("[SyntheticTestMediaFactory] Failed to write the SCC captions for \(preset.rawValue)")
                return nil
            }
        }

        let encodedPath = partialPath()
        defer { try? FileManager.default.removeItem(atPath: encodedPath) }
        if preset.hasCaptionSEI {
            // A raw H.264 stream, its pictures given caption SEI here, then muxed.
            let streamPath = tmpDir.appendingPathComponent(".partial-\(UUID().uuidString).h264").path
            defer { try? FileManager.default.removeItem(atPath: streamPath) }
            let encode = [
                "-y", "-f", "lavfi", "-i", "color=c=gray:size=320x240:rate=30:duration=6",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-bf", "0", "-g", "30", "-x264-params", "aud=1",
                "-f", "h264", streamPath,
            ]
            guard runFFmpeg(ffmpeg, arguments: encode, preset: preset),
                let stream = FileManager.default.contents(atPath: streamPath),
                FileManager.default.createFile(atPath: streamPath, contents: captionedStream(stream)),
                runFFmpeg(
                    ffmpeg,
                    arguments: [
                        "-y", "-f", "h264", "-framerate", "30", "-i", streamPath, "-c", "copy",
                        "-f", preset == .captionsH264TS ? "mpegts" : "matroska", encodedPath,
                    ], preset: preset)
            else { return nil }
            guard rename(encodedPath, targetPath) == 0 else {
                print("[SyntheticTestMediaFactory] Failed to publish \(preset.rawValue): errno \(errno)")
                return nil
            }
            return targetPath
        }
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
        if preset == .hevcInBandParameterSetsMKV {
            guard let file = FileManager.default.contents(atPath: readyPath),
                let patched = emptyingHVCCParameterSets(in: file),
                FileManager.default.createFile(atPath: readyPath, contents: patched)
            else {
                print("[SyntheticTestMediaFactory] Failed to empty the hvcC of \(preset.rawValue)")
                return nil
            }
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
        case .captionsH264TS, .captionsH264MKV:
            return []  // Made in steps by `generateMedia`.
        case .captionsC608MOV, .captionsC608FragmentedMOV:
            return [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=320x240:rate=30:duration=6",
                "-f", "scc", "-i", metadataPath,
                "-map", "0:v", "-map", "1:s",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", "copy",
                "-f", "mov",
            ] + (preset == .captionsC608FragmentedMOV ? ["-g", "30", "-movflags", "frag_keyframe+empty_moov"] : []) + [
                outputPath
            ]
        case .assSubtitlesMKV:
            return [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=640x360:rate=24:duration=6",
                "-f", "ass", "-i", metadataPath,
                "-map", "0:v", "-map", "1:s",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", "copy",
                "-metadata:s:s:0", "language=eng",
                outputPath,
            ]
        case .assFadeSubtitlesMKV:
            return [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=640x360:rate=60:duration=4",
                "-f", "ass", "-i", metadataPath,
                "-map", "0:v", "-map", "1:s",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", "copy",
                "-metadata:s:s:0", "language=eng",
                outputPath,
            ]
        case .pgsSubtitlesMKV:
            return [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=320x240:rate=24:duration=6",
                "-f", "sup", "-i", metadataPath,
                "-map", "0:v", "-map", "1:s",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", "copy",
                "-metadata:s:s:0", "language=eng",
                outputPath,
            ]
        case .dvbSubtitlesTS:
            return [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=320x240:rate=24:duration=6",
                "-f", "sup", "-i", metadataPath,
                "-map", "0:v", "-map", "1:s",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:s", "dvbsub",
                "-metadata:s:s:0", "language=eng",
                "-f", "mpegts",
                outputPath,
            ]
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

        case .h264HFR60:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=60:duration=20",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=20",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "60",
                "-c:a", "aac", "-b:a", "128k",
                outputPath,
            ]

        case .videoOnlyH264:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=20",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24",
                "-an",
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

        case .mpeg4XvidAVI:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=5",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                "-c:v", "mpeg4", "-vtag", "XVID", "-q:v", "4", "-bf", "2", "-g", "24",
                "-c:a", "libmp3lame", "-b:a", "128k",
                outputPath,
            ]

        case .msmpeg4v3AVI:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "msmpeg4", "-vtag", "DIV3", "-q:v", "4", "-g", "24",
                "-c:a", "mp2", "-b:a", "192k",
                outputPath,
            ]

        case .h263CIF3GP:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=352x288:rate=15:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "h263", "-q:v", "5", "-g", "15",
                "-c:a", "aac", "-ar", "16000", "-ac", "1", "-b:a", "32k",
                outputPath,
            ]

        case .h263pMKV:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-c:v", "h263p", "-q:v", "5", "-g", "24",
                outputPath,
            ]

        case .mpeg2DVDVOB:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=30000/1001:duration=4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                "-c:v", "mpeg2video", "-b:v", "6000k", "-maxrate", "9000k", "-bufsize", "1835k",
                "-bf", "2", "-g", "15", "-aspect", "16:9",
                "-c:a", "ac3", "-b:a", "192k", "-ar", "48000",
                outputPath,
            ]

        case .mpeg2InterlacedTS:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=50:duration=4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                "-vf", "tinterlace=mode=interleave_top,setfield=tff",
                "-c:v", "mpeg2video", "-b:v", "5000k", "-bf", "2", "-g", "12", "-aspect", "4:3",
                "-flags", "+ilme+ildct",
                "-c:a", "mp2", "-b:a", "192k",
                outputPath,
            ]

        case .mpeg1MPG:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=352x240:rate=30000/1001:duration=4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                "-c:v", "mpeg1video", "-b:v", "1150k", "-bf", "2", "-g", "15",
                "-c:a", "mp2", "-b:a", "224k",
                outputPath,
            ]

        case .flvSpark:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                "-c:v", "flv", "-q:v", "5", "-g", "25",
                "-c:a", "libmp3lame", "-ar", "22050", "-b:a", "64k",
                outputPath,
            ]

        case .vp8WebM:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                "-c:v", "libvpx", "-b:v", "1M", "-g", "30",
                "-c:a", "vorbis", "-strict", "experimental", "-ac", "2",
                outputPath,
            ]

        case .rv10RM:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                "-c:v", "rv10", "-q:v", "5", "-g", "15",
                "-c:a", "real_144", "-ar", "8000", "-ac", "1",
                outputPath,
            ]

        case .rv20RM:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=352x288:rate=25:duration=4",
                "-c:v", "rv20", "-q:v", "5", "-g", "25",
                outputPath,
            ]

        case .mjpegAVI:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "mjpeg", "-pix_fmt", "yuvj422p", "-q:v", "4",
                "-c:a", "pcm_s16le",
                outputPath,
            ]

        case .dvNTSC:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=30000/1001:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:v", "dvvideo", "-pix_fmt", "yuv411p",
                "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
                outputPath,
            ]

        case .cinepakMOV:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=3",
                "-c:v", "cinepak",
                outputPath,
            ]

        case .proresMOV:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
                "-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le",
                outputPath,
            ]

        case .h264InterlacedTS:
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=50:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-vf", "tinterlace=mode=interleave_top,setfield=tff",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme", "-x264-params", "tff=1",
                "-g", "25", "-aspect", "4:3",
                "-c:a", "mp2", "-b:a", "192k",
                outputPath,
            ]

        case .interlacedStaticDetailTS:
            return [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=720x576:rate=50:duration=2",
                "-vf",
                "format=yuv420p,geq=lum='if(mod(Y,2),64,192)':cb=128:cr=128,tinterlace=mode=interleave_top,"
                    + "setfield=tff",
                "-c:v", "mpeg2video", "-q:v", "2", "-g", "12", "-flags", "+ilme+ildct", "-aspect", "4:3",
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

        case .hevcInBandParameterSetsMKV:
            // 64-sample PCM frames: one packet each, 750 a second (TrueHD has 1200).
            return [
                "-y",
                "-itsoffset", "8", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:samples_per_frame=64:duration=11",
                "-map", "0:v", "-map", "1:a",
                "-c:v", "libx265", "-pix_fmt", "yuv420p", "-x265-params", "repeat-headers=1:log-level=error",
                "-c:a", "pcm_s16le",
                outputPath,
            ]
        }
    }

    /// The Matroska file with the parameter-set count of its `hvcC` CodecPrivate set to zero. The arrays stay as
    /// unread bytes, so no element size changes.
    static func emptyingHVCCParameterSets(in file: Data) -> Data? {
        var bytes = [UInt8](file)
        var index = 0
        // CodecPrivate (0x63A2) with a one- or two-byte size, then an hvcC (configurationVersion 1, 23+ bytes).
        while index + 4 < bytes.count {
            if bytes[index] == 0x63, bytes[index + 1] == 0xA2, bytes[index + 2] & 0xC0 != 0 {
                let isShortSize = bytes[index + 2] & 0x80 != 0
                let size =
                    isShortSize
                    ? Int(bytes[index + 2] & 0x7F) : Int(bytes[index + 2] & 0x3F) << 8 | Int(bytes[index + 3])
                let start = index + (isShortSize ? 3 : 4)
                if size >= 23, start + size <= bytes.count, bytes[start] == 1 {
                    bytes[start + 22] = 0
                    return Data(bytes)
                }
            }
            index += 1
        }
        return nil
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

extension SyntheticTestMediaFactory {
    /// The bar `pgsStream` draws, on its 320x240 canvas.
    static let pgsBar = (x: 96, y: 180, width: 128, height: 32)

    /// A hand-built PGS stream (`.sup`): the white `pgsBar` shown from 0 s to 1.5 s (an empty display set clears
    /// it), then again from 2.5 s with no end. FFmpeg shifts the first set to 0 when it reads the stream, so it starts there. It can mux PGS but not encode it, and a few hundred bytes made
    /// here keep binary files out of the repository.
    static var pgsStream: Data { pgsStream() }

    /// `pgsStream` with the bar of the set at `forcedAt` marked forced (composition flag 0x40).
    static func pgsStream(forcedAt forced: Double? = nil) -> Data {
        func segment(_ type: UInt8, at seconds: Double, _ payload: [UInt8]) -> [UInt8] {
            let pts = UInt32(seconds * 90_000)
            func be32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
            func be16(_ value: Int) -> [UInt8] {
                [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
            }
            return [0x50, 0x47] + be32(pts) + be32(0) + [type] + be16(payload.count) + payload
        }
        func be16(_ value: Int) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        let bar = pgsBar

        // Per row: a run of `width` pixels of color 1 (14-bit length form), then end of line.
        let row: [UInt8] = [0x00, 0xC0 | UInt8(bar.width >> 8), UInt8(bar.width & 0xFF), 0x01, 0x00, 0x00]
        let bitmap = Array((0..<bar.height).map { _ in row }.joined())

        func displaySet(at seconds: Double, composition: Int, showing: Bool) -> [UInt8] {
            // Video size, 24 fps, composition number, epoch start, no palette update, palette 0, object count.
            var pcs = be16(320) + be16(240) + [0x20] + be16(composition) + [0x80, 0x00, 0x00, showing ? 1 : 0]
            if showing { pcs += be16(0) + [0x00, seconds == forced ? 0x40 : 0x00] + be16(bar.x) + be16(bar.y) }
            var set = segment(0x16, at: seconds, pcs)
            if showing {
                set += segment(
                    0x17, at: seconds, [1, 0] + be16(bar.x) + be16(bar.y) + be16(bar.width) + be16(bar.height))
                // Palette 0, version 0; entry 1: white (Y 235, Cr 128, Cb 128), opaque.
                set += segment(0x14, at: seconds, [0, 0, 1, 235, 128, 128, 255])
                // Object 0, version 0, first and last fragment, data length (with the 4 size bytes), width, height.
                let length = bitmap.count + 4
                set += segment(
                    0x15, at: seconds,
                    be16(0) + [0, 0xC0, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
                        + be16(bar.width) + be16(bar.height) + bitmap)
            }
            return set + segment(0x80, at: seconds, [])
        }

        return Data(
            displaySet(at: 0, composition: 0, showing: true) + displaySet(at: 1.5, composition: 1, showing: false)
                + displaySet(at: 2.5, composition: 2, showing: true))
    }
}

extension SyntheticTestMediaFactory {
    /// The CEA-608 captions of the caption presets, in CC1 and popped on: when each is shown and cleared, its row (1
    /// or 15) and text. 608 carries Latin text only.
    static let captionScript: [(shown: Double, cleared: Double, row: Int, text: String)] = [
        (1.0, 2.5, 15, "HELLO WORLD"),
        (3.0, 4.5, 1, "TOP LINE"),
    ]

    /// A 608 byte with its odd parity bit.
    static func cea608Byte(_ value: UInt8) -> UInt8 {
        value.nonzeroBitCount % 2 == 0 ? value | 0x80 : value
    }

    /// The pairs (parity added) that load a caption off screen at `row` and show it, control codes doubled as
    /// encoders send them: resume caption loading, preamble for the row, the text, end of caption (shown here).
    static func popOnPairs(row: Int, text: String) -> [(UInt8, UInt8)] {
        let preamble: (UInt8, UInt8) = row == 15 ? (0x14, 0x60) : (0x11, 0x40)
        let characters = Array(text.utf8)
        let textPairs = stride(from: 0, to: characters.count, by: 2).map {
            (characters[$0], $0 + 1 < characters.count ? characters[$0 + 1] : 0)
        }
        let pairs = [(0x14, 0x20), (0x14, 0x20), preamble, preamble] + textPairs + [(0x14, 0x2F), (0x14, 0x2F)]
        return pairs.map { (cea608Byte($0.0), cea608Byte($0.1)) }
    }

    /// Erase displayed memory, doubled.
    static let clearPairs = [(cea608Byte(0x14), cea608Byte(0x2C)), (cea608Byte(0x14), cea608Byte(0x2C))]

    /// The field 1 pair of each picture at 30 fps: a caption's end of caption falls on the picture it is shown at.
    static var captionPairsPerPicture: [(UInt8, UInt8)] {
        var pictures = Array(repeating: (cea608Byte(0), cea608Byte(0)), count: 180)
        for caption in captionScript {
            let pairs = popOnPairs(row: caption.row, text: caption.text)
            let shown = Int((caption.shown * 30).rounded())
            for (offset, pair) in pairs.enumerated() { pictures[shown - (pairs.count - 2) + offset] = pair }
            let cleared = Int((caption.cleared * 30).rounded())
            for (offset, pair) in clearPairs.enumerated() { pictures[cleared + offset] = pair }
        }
        return pictures
    }

    /// An H.264 SEI unit with ATSC `cc_data` holding `pair` for field 1, null padding for field 2 and a CEA-708
    /// triplet, as broadcast encoders write it; emulation prevention applied.
    static func captionSEI(pair: (UInt8, UInt8)) -> [UInt8] {
        let triplets: [UInt8] = [0xFC, pair.0, pair.1, 0xFD, 0x80, 0x80, 0xFF, 0x02, 0x21]
        let payload: [UInt8] = [0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03, 0x40 | 3, 0xFF] + triplets + [0xFF]
        return [0x06] + emulationPrevented([0x04, UInt8(payload.count)] + payload + [0x80])
    }

    /// Inserts `03` after two zero bytes followed by a byte up to 3, as a NAL unit's payload must have it.
    static func emulationPrevented(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 3 {
                result.append(3)
                zeros = 0
            }
            zeros = byte == 0 ? zeros + 1 : 0
            result.append(byte)
        }
        return result
    }

    /// An Annex B H.264 stream with an access unit delimiter per picture, given `captionSEI` after each delimiter.
    static func captionedStream(_ stream: Data) -> Data {
        let bytes = [UInt8](stream)
        var starts: [Int] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index + 3)
                index += 3
            } else {
                index += 1
            }
        }
        let pairs = captionPairsPerPicture
        var picture = 0
        var result: [UInt8] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            result += [0, 0, 0, 1] + bytes[start..<end]
            if bytes[start] & 0x1F == 9 {
                result += [0, 0, 0, 1] + captionSEI(pair: picture < pairs.count ? pairs[picture] : (0x80, 0x80))
                picture += 1
            }
        }
        return Data(result)
    }

    /// `captionScript` as a Scenarist SCC file: each caption's pairs at the time it is shown, its clear at the time
    /// it is cleared. FFmpeg drops the last line when muxing it into MOV, so one more clear ends the file.
    static var captionSCC: String {
        func timecode(_ seconds: Double) -> String {
            let frames = Int((seconds * 30).rounded())
            return String(format: "00:00:%02d:%02d", frames / 30, frames % 30)
        }
        func words(_ pairs: [(UInt8, UInt8)]) -> String {
            pairs.map { String(format: "%02x%02x", $0.0, $0.1) }.joined(separator: " ")
        }
        var lines = ["Scenarist_SCC V1.0", ""]
        for caption in captionScript {
            lines += [timecode(caption.shown) + "\t" + words(popOnPairs(row: caption.row, text: caption.text)), ""]
            lines += [timecode(caption.cleared) + "\t" + words(clearPairs), ""]
        }
        lines += [timecode(5.5) + "\t" + words(clearPairs), ""]
        return lines.joined(separator: "\n")
    }
}
