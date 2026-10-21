import CFFmpeg
import CoreMedia
import Foundation

extension MediaDemuxer {
    // MARK: - Stream discovery

    /// Adopts `stream` as the video stream: geometry, timing, colorimetry, Dolby Vision and HDR metadata.
    func configureVideoStream(
        _ stream: UnsafeMutablePointer<AVStream>, index: Int, codec detectedCodec: VideoCodec,
        in formatCtx: UnsafeMutablePointer<AVFormatContext>
    ) {
        let codecpar = stream.pointee.codecpar!
        self.videoStreamIndex = index
        self.timebase = stream.pointee.time_base
        self.codec = detectedCodec
        self.width = Int(codecpar.pointee.width)
        self.height = Int(codecpar.pointee.height)

        // Guess or extract Sample Aspect Ratio (SAR / PAR)
        let guessedSAR = av_guess_sample_aspect_ratio(formatCtx, stream, nil)
        if guessedSAR.num > 0 && guessedSAR.den > 0 {
            self.sampleAspectRatio = RationalAspectRatio(
                numerator: Int(guessedSAR.num), denominator: Int(guessedSAR.den))
        } else if stream.pointee.sample_aspect_ratio.num > 0 && stream.pointee.sample_aspect_ratio.den > 0 {
            self.sampleAspectRatio = RationalAspectRatio(
                numerator: Int(stream.pointee.sample_aspect_ratio.num),
                denominator: Int(stream.pointee.sample_aspect_ratio.den)
            )
        } else if codecpar.pointee.sample_aspect_ratio.num > 0 && codecpar.pointee.sample_aspect_ratio.den > 0 {
            self.sampleAspectRatio = RationalAspectRatio(
                numerator: Int(codecpar.pointee.sample_aspect_ratio.num),
                denominator: Int(codecpar.pointee.sample_aspect_ratio.den)
            )
        } else {
            self.sampleAspectRatio = .square
        }

        if stream.pointee.duration > 0 {
            self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
        } else if formatCtx.pointee.duration > 0 {
            self.durationSeconds = Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // Nominal frame duration from the average frame rate, else the base rate (DV can report an average of
        // 60000 fps), within a sanity range of 1 to 240 fps.
        let plausibleDuration = { (rate: AVRational) -> Double? in
            guard rate.num > 0 && rate.den > 0 else { return nil }
            let duration = Double(rate.den) / Double(rate.num)
            return duration >= (1.0 / 240.0) && duration <= 1.0 ? duration : nil
        }
        self.nominalFrameDuration =
            plausibleDuration(stream.pointee.avg_frame_rate) ?? plausibleDuration(stream.pointee.r_frame_rate)
            ?? (1.0 / 24.0)

        let fieldOrder = codecpar.pointee.field_order
        let isStandardDefinitionDV = codecpar.pointee.codec_id == AV_CODEC_ID_DVVIDEO && height <= 576
        self.isInterlaced =
            fieldOrder == AV_FIELD_UNKNOWN ? isStandardDefinitionDV : fieldOrder != AV_FIELD_PROGRESSIVE

        let colorimetry = StreamColorimetry(codecParameters: codecpar, width: width, height: height)
        self.colorPrimaries = colorimetry.colorPrimaries
        self.transferFunction = colorimetry.transferFunction
        self.yCbCrMatrix = colorimetry.yCbCrMatrix
        self.isFullRange = colorimetry.isFullRange
        self.bitDepth = colorimetry.bitDepth

        // Dolby Vision Detection (Profiles 5, 8.1, 8.4):
        // In MP4/MKV it is identified by dvvC/dvcC box (or stream side data).
        // Profile 5 uses IPTc2 color space with PQ transfer function.
        // Profile 8 uses standard BT.2020 PQ (8.1) or HLG (8.4) with dynamic RPU metadata.
        if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size >= 24 {
            let extraData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            if let parsed = HDRMetadataEncoding.parseDolbyVisionConfigurationBox(from: extraData) {
                self.dolbyVisionProfile = parsed.profile
                self.dolbyVisionCompatibilityId = parsed.compatibilityId
                self.dolbyVisionConfigData = parsed.configData
                self.bitDepth = 10
                if parsed.profile == 5 {
                    self.isDolbyVisionProfile5 = true
                }
                AppLog.info(
                    .video,
                    "Detected Dolby Vision Profile \(parsed.profile) (dvcC/dvvC payload: \(parsed.configData.count) bytes, compatibility id: \(parsed.compatibilityId))"
                )
            }
        }

        readHDRSideData(of: codecpar)
    }

    /// Dolby Vision configuration (when extradata had none), content light level and mastering display from
    /// the stream's coded side data. Mastering luminance only fills in a peak still at its 1000-nit default.
    func readHDRSideData(of codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let sideDataCount = Int(codecpar.pointee.nb_coded_side_data)
        guard sideDataCount > 0, let sideDataList = codecpar.pointee.coded_side_data else { return }
        for s in 0..<sideDataCount {
            let sd = sideDataList[s]
            if self.dolbyVisionProfile == nil && sd.type == AV_PKT_DATA_DOVI_CONF, let sdData = sd.data,
                sd.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            {
                let doviConf = UnsafeMutableRawPointer(sdData).assumingMemoryBound(
                    to: AVDOVIDecoderConfigurationRecord.self)
                let dvProfile = Int(doviConf.pointee.dv_profile)
                let compatId = Int(doviConf.pointee.dv_bl_signal_compatibility_id & 0x0F)
                self.dolbyVisionProfile = dvProfile
                self.dolbyVisionCompatibilityId = compatId
                self.bitDepth = 10
                if dvProfile == 5 {
                    self.isDolbyVisionProfile5 = true
                }
                self.dolbyVisionConfigData = HDRMetadataEncoding.dolbyVisionConfigurationBox(doviConf.pointee)
                AppLog.info(
                    .video,
                    "Detected Dolby Vision Profile \(dvProfile) via FFmpeg side data (compatibility id: \(compatId))"
                )
            } else if sd.type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL, let sdData = sd.data,
                sd.size >= MemoryLayout<AVContentLightMetadata>.size
            {
                let clm = UnsafeMutableRawPointer(sdData).assumingMemoryBound(to: AVContentLightMetadata.self)
                if clm.pointee.MaxCLL > 0 {
                    self.maxPeakNits = Float(clm.pointee.MaxCLL)
                }
                if clm.pointee.MaxFALL > 0 {
                    self.maxFallNits = Float(clm.pointee.MaxFALL)
                }
                self.contentLightLevel = HDRMetadataEncoding.contentLightLevelInfo(clm.pointee)
                AppLog.info(
                    .video,
                    "Extracted ContentLightLevel from side data: MaxCLL=\(clm.pointee.MaxCLL), MaxFALL=\(clm.pointee.MaxFALL)"
                )
            } else if sd.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA, let sdData = sd.data,
                sd.size >= MemoryLayout<AVMasteringDisplayMetadata>.size
            {
                let mdm = UnsafeMutableRawPointer(sdData).assumingMemoryBound(to: AVMasteringDisplayMetadata.self)
                if mdm.pointee.has_luminance != 0 && mdm.pointee.max_luminance.den > 0 {
                    let maxLum = Float(mdm.pointee.max_luminance.num) / Float(mdm.pointee.max_luminance.den)
                    if self.maxPeakNits == 1000.0 && maxLum > 0 {
                        self.maxPeakNits = maxLum
                    }
                }
                if mdm.pointee.has_primaries != 0 && mdm.pointee.has_luminance != 0 {
                    self.masteringDisplay = HDRMetadataEncoding.masteringDisplayColourVolume(mdm.pointee)
                }
            }
        }
    }

    /// Lists an audio stream as a track; the first one becomes the active track.
    func registerAudioTrack(_ stream: UnsafeMutablePointer<AVStream>, index: Int) {
        let codecId = stream.pointee.codecpar.pointee.codec_id
        // Read track metadata (title, language)
        var title = ""
        var lang = ""
        if let titleTag = av_dict_get(stream.pointee.metadata, "title", nil, 0) {
            title = String(cString: titleTag.pointee.value)
        }
        if let langTag = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
            lang = String(cString: langTag.pointee.value)
        }
        let codecNameStr: String
        if let codecDesc = avcodec_descriptor_get(codecId), let name = codecDesc.pointee.name {
            codecNameStr = String(cString: name)
        } else {
            codecNameStr = "audio"
        }

        let track = AudioTrack(
            id: self.audioTracks.count,
            streamIndex: index,
            title: title,
            language: lang,
            codecName: codecNameStr,
            channels: Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels),
            sampleRate: Int(stream.pointee.codecpar.pointee.sample_rate),
            isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0
        )
        self.audioTracks.append(track)

        if self.audioStreamIndex < 0 {
            // First audio stream found - select as default
            self.audioStreamIndex = index
            self.selectedAudioTrackIndex = track.id
            self.audioTimebase = stream.pointee.time_base
            self.audioCodecId = codecId
            self.hasAudio = true
            self.audioChannels = track.channels
            self.audioSampleRate = track.sampleRate
            if let ed = stream.pointee.codecpar.pointee.extradata, stream.pointee.codecpar.pointee.extradata_size > 0 {
                self.audioExtraData = Data(bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
            }
        }
    }

    /// Whether a subtitle stream is forced or for the hard of hearing: Matroska and MP4 flag the stream itself, and many
    /// files leave the title empty; older ones only say so in the title.
    static func subtitleFlags(title: String, disposition: Int32) -> (isForced: Bool, isSDH: Bool) {
        (
            (disposition & AV_DISPOSITION_FORCED) != 0 || title.localizedCaseInsensitiveContains("forced"),
            (disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0 || title.localizedCaseInsensitiveContains("sdh")
        )
    }

    /// Lists a text (SRT, WebVTT, mov_text, plain text, ASS, SSA) or bitmap (PGS, VobSub, DVB) subtitle stream as a
    /// track. Plain text is Matroska's `S_TEXT/ASCII`: the packet is the line. An MP4 caption track (`c608`) is CEA-608
    /// closed captions, read from field 1.
    func registerSubtitleTrack(_ stream: UnsafeMutablePointer<AVStream>, index: Int) {
        let codecId = stream.pointee.codecpar.pointee.codec_id
        let isCaptions = codecId == AV_CODEC_ID_EIA_608
        let isTextSub =
            (codecId == AV_CODEC_ID_SUBRIP || codecId == AV_CODEC_ID_WEBVTT || codecId == AV_CODEC_ID_MOV_TEXT
                || codecId == AV_CODEC_ID_TEXT || codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA)
        let isBitmapSub = BitmapSubtitleDecoder.isBitmapCodec(codecId)
        guard isTextSub || isBitmapSub || isCaptions else { return }
        var title = ""
        var lang = ""
        if let titleTag = av_dict_get(stream.pointee.metadata, "title", nil, 0) {
            title = String(cString: titleTag.pointee.value)
        }
        if let langTag = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
            lang = String(cString: langTag.pointee.value)
        }
        let (isForced, isSDH) = Self.subtitleFlags(title: title, disposition: stream.pointee.disposition)
        let displayTitle =
            title.isEmpty
            ? (lang.isEmpty ? (isCaptions ? "CC1" : "Subtitle \(self.subtitleTracks.count + 1)") : lang.uppercased())
            : title

        let subTrack = SubtitleTrack(
            id: self.subtitleTracks.count,
            streamIndex: index,
            title: displayTitle,
            language: lang,
            isForced: isForced,
            isSDH: isSDH || isCaptions,
            isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
            format: isBitmapSub ? .bitmap : (codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA ? .ass : .text),
            closedCaptionField: isCaptions ? 0 : nil
        )
        self.subtitleTracks.append(subTrack)
    }

    /// Lists the CEA-608 closed captions found in the first pictures (`closedCaptionFields`) as tracks of the video
    /// stream: CC1 for field 1, CC3 for field 2. They are for the hard of hearing by nature.
    func registerClosedCaptionTracks() {
        for field in closedCaptionFields.sorted() {
            subtitleTracks.append(
                SubtitleTrack(
                    id: subtitleTracks.count, streamIndex: videoStreamIndex, title: field == 0 ? "CC1" : "CC3",
                    language: "", isSDH: true, format: .text, closedCaptionField: field, captionsInVideo: true))
        }
    }

    /// Container chapters as FFmpeg exports them (MKV default edition, flattened; MP4 chapter track or
    /// Nero `chpl`). Chapters without a start are skipped; an unset end stays `nil`.
    static func readChapters(from formatCtx: UnsafeMutablePointer<AVFormatContext>) -> [MediaChapter.Raw] {
        let count = Int(formatCtx.pointee.nb_chapters)
        guard count > 0, let list = formatCtx.pointee.chapters else { return [] }
        let noPTS = Int64.min  // AV_NOPTS_VALUE
        return (0..<count).compactMap { index in
            guard let chapter = list[index]?.pointee, chapter.start != noPTS,
                chapter.time_base.num > 0, chapter.time_base.den > 0
            else { return nil }
            let num = Double(chapter.time_base.num)
            let den = Double(chapter.time_base.den)
            let title = av_dict_get(chapter.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) }
            return MediaChapter.Raw(
                title: title,
                start: Double(chapter.start) * num / den,
                end: chapter.end != noPTS && chapter.end > chapter.start ? Double(chapter.end) * num / den : nil
            )
        }
    }

    func extractVideoFormatDescription() -> CMVideoFormatDescription? {
        guard let ctx = formatCtx else { return nil }
        let codecParameters: UnsafePointer<AVCodecParameters>? =
            videoStreamIndex >= 0
            ? ctx.pointee.streams[videoStreamIndex].map { UnsafePointer($0.pointee.codecpar) } : nil

        // Step 1: Try parsing from container extradata (avcC / hvcC / Annex B header)
        var parameterSets = VideoFormatDescriptionBuilder.ParameterSets()
        if let codecpar = codecParameters, let extradata = codecpar.pointee.extradata,
            codecpar.pointee.extradata_size > 0,
            let parsed = VideoFormatDescriptionBuilder.parameterSets(
                fromExtradata: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size)), codec: codec)
        {
            parameterSets = parsed.sets
            self.isAnnexBStream = parsed.isAnnexB
        }
        var (vps, sps, pps) = (parameterSets.vps, parameterSets.sps, parameterSets.pps)
        var masteringDisplay: Data?
        var contentLightLevel: Data?

        let hasExtradataParams: Bool
        if codec == .hevc {
            hasExtradataParams = (vps != nil && sps != nil && pps != nil)
        } else {
            hasExtradataParams = (sps != nil && pps != nil)
        }

        // Step 2: Fallback to scanning packets if extradata is missing or for SEI mastering info
        var packetsScanned = 0
        let maxPacketsToScan = hasExtradataParams ? 30 : 120
        var pkt = AVPacket()
        let nalLengthSize = codecParameters.map { ClosedCaptions.nalLengthSize(of: $0, codec: codec) } ?? 4

        while packetsScanned < maxPacketsToScan && readPacket(ctx, &pkt) >= 0 {
            packetsScanned += 1
            if pkt.stream_index == videoStreamIndex {
                if let bytes = pkt.data {
                    let packet = UnsafeRawBufferPointer(start: bytes, count: Int(pkt.size))
                    closedCaptionFields.formUnion(
                        ClosedCaptions.fields(
                            of: ClosedCaptions.cea608Triplets(in: packet, codec: codec, lengthSize: nalLengthSize)))
                }
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                // If extradata was missing or empty, detect whether the stream is Annex B from the first video packet
                if !hasExtradataParams && packetsScanned == 1 && data.count >= 3 {
                    if data[0] == 0 && data[1] == 0
                        && (data[2] == 1 || (data.count > 3 && data[2] == 0 && data[3] == 1))
                    {
                        self.isAnnexBStream = true
                    }
                }
                let nalus = NALUnitParser.extractNALUnits(from: data, isAnnexB: self.isAnnexBStream)
                for naluData in nalus {
                    guard !naluData.isEmpty else { continue }
                    if codec == .hevc {
                        let nalType = (naluData[0] >> 1) & 0x3F
                        if vps == nil && nalType == 32 {
                            vps = naluData
                        } else if sps == nil && nalType == 33 {
                            sps = naluData
                        } else if pps == nil && nalType == 34 {
                            pps = naluData
                        } else if nalType == 39 {
                            applyHDRSEI(
                                naluData: naluData, masteringDisplay: &masteringDisplay,
                                contentLightLevel: &contentLightLevel)
                        }
                    } else if codec == .h264 {
                        let nalType = naluData[0] & 0x1F
                        if sps == nil && nalType == 7 {
                            sps = naluData
                        } else if pps == nil && nalType == 8 {
                            pps = naluData
                        }
                    }
                }
                av_packet_unref(&pkt)

                let hasParameters: Bool
                if codec == .hevc {
                    hasParameters = (vps != nil && sps != nil && pps != nil)
                } else if codec == .h264 {
                    hasParameters = (sps != nil && pps != nil)
                } else {
                    hasParameters = true
                }

                if hasParameters && (masteringDisplay != nil || packetsScanned > 20) {
                    break
                }
            } else {
                av_packet_unref(&pkt)
            }
        }

        // Rewind to the beginning. A timestamp seek in MPEG-TS / MPEG-PS bisects and can land past the first
        // packet, dropping the keyframe that starts the file (H.264 then can't decode its first GOP). Their data
        // starts at the first byte, so rewind there.
        if Self.isUnindexedStream(ctx) {
            avformat_seek_file(ctx, -1, Int64.min, 0, 0, AVSEEK_FLAG_BYTE)
        } else {
            av_seek_frame(
                ctx, Int32(videoStreamIndex), Self.timelineOffset(timelineOrigin, in: timebase), AVSEEK_FLAG_BACKWARD)
        }
        readAheadState.withLock { $0 = -.infinity }
        subtitleTracker.resetStash()

        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel

        let builder = VideoFormatDescriptionBuilder(
            codec: codec,
            width: width,
            height: height,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            isFullRange: isFullRange,
            bitDepth: bitDepth,
            sampleAspectRatio: sampleAspectRatio,
            masteringDisplay: masteringDisplay,
            contentLightLevel: contentLightLevel,
            parameterSets: .init(vps: vps, sps: sps, pps: pps),
            dolbyVision: dolbyVisionProfile.flatMap { profile in
                dolbyVisionConfigData.map { (profile: profile, configData: $0) }
            }
        )
        return builder.make(codecParameters: codecParameters)
    }

    /// Collects HDR metadata from an HEVC prefix SEI NAL unit. Mastering display luminance only fills in
    /// a peak still at its 1000-nit default; MaxCLL overrides it.
    func applyHDRSEI(naluData: Data, masteringDisplay: inout Data?, contentLightLevel: inout Data?) {
        for message in VideoFormatDescriptionBuilder.hdrSEIMessages(inPrefixSEI: naluData) {
            switch message {
            case .masteringDisplay(let data, let maxLuminanceNits):
                masteringDisplay = data
                if self.maxPeakNits == 1000.0 && maxLuminanceNits > 0 {
                    self.maxPeakNits = maxLuminanceNits
                }
            case .contentLightLevel(let data, let maxCLL, let maxFALL):
                contentLightLevel = data
                if maxCLL > 0 {
                    self.maxPeakNits = Float(maxCLL)
                }
                if maxFALL > 0 {
                    self.maxFallNits = Float(maxFALL)
                }
            }
        }
    }
}
