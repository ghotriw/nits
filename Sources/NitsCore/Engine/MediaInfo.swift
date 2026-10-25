import CoreVideo
import Foundation

/// What describes the media loaded: read from its demuxer when a load applies it, changed after only by an HLS
/// variant switch (the picture's size and pixel aspect), and empty while none is loaded. The engine replaces it whole
/// on every load and reset, so nothing of one media can describe the next.
public struct MediaInfo: Equatable, Sendable {
    public var duration: Double = 0
    public var chapters: [MediaChapter] = []
    public var hasVideo = false
    /// Read over a network, and so ahead of playback by up to half a minute (`PlayerEngine.bufferedTime`); a local
    /// file is read only the few seconds the feeders ask for.
    public var isNetworkSource = false
    /// The video stream; empty when there is none (`hasVideo`).
    public var video = VideoInfo()

    public init() {}

    /// The video stream of the media loaded, as the media info pane and the debug HUD show it.
    public struct VideoInfo: Equatable, Sendable {
        public var width = 0
        public var height = 0
        public var sampleAspectRatio = RationalAspectRatio.square
        /// Declared interlaced: the decoder deinterlaces it (`MetalDeinterlacer`).
        public var isInterlaced = false
        /// PQ or HLG: tone-mapped with Metal on an SDR display.
        public var isHDR = false
        public var codecName = ""
        public var bitDepth = 8
        /// "BT.709", "BT.601", "DCI-P3", "BT.2020" or "Unknown" (`ColorPrimariesClass`).
        public var colorPrimaries = ""
        /// The transfer function, or the Dolby Vision profile that stands for it.
        public var transferFunction = ""
        /// "Profile 8.1 (HDR10 Base)" and the like; `nil` without Dolby Vision.
        public var dolbyVisionProfile: String?
        /// Peak luminance of the content in nits (MaxCLL or the mastering display's), 0 when the stream gives none.
        public var sourcePeakNits: Float = 0

        public init() {}

        /// Display aspect ratio of the picture: its size and pixel aspect, before the player's override and crop.
        public var displayAspectRatio: Double {
            RationalAspectRatio.computeDisplayAspectRatio(width: width, height: height, sar: sampleAspectRatio)
        }
    }
}

extension MediaInfo {
    /// Reads the description of the media `demuxer` has just opened (before it reads ahead).
    init(demuxer: MediaDemuxer, fallbackChapters: [MediaChapter] = []) {
        duration = demuxer.durationSeconds
        chapters = !demuxer.chapters.isEmpty ? demuxer.chapters : fallbackChapters
        hasVideo = demuxer.hasVideo
        isNetworkSource = demuxer.isNetworkSource
        guard demuxer.hasVideo else { return }
        video.width = demuxer.width
        video.height = demuxer.height
        video.sampleAspectRatio = demuxer.sampleAspectRatio
        video.isInterlaced = demuxer.isInterlaced
        video.isHDR = demuxer.isHDR
        video.codecName = demuxer.codec.displayName
        video.bitDepth = demuxer.bitDepth
        video.sourcePeakNits = demuxer.maxPeakNits

        video.colorPrimaries =
            ToneMapController.shaderColor(
                primaries: demuxer.colorPrimaries, transferFunction: demuxer.transferFunction,
                isDolbyVisionProfile5: demuxer.isDolbyVisionProfile5
            ).0.label
        if demuxer.isDolbyVisionProfile5 {
            video.transferFunction = "Dolby Vision (Profile 5 ICtCp)"
        } else if let profile = demuxer.dolbyVisionProfileString {
            video.transferFunction = "Dolby Vision (Profile \(profile))"
        } else {
            video.transferFunction = TransferFunctionClass(demuxer.transferFunction).label
        }

        if demuxer.isDolbyVisionProfile5 {
            video.dolbyVisionProfile = "Profile 5 (ICtCp)"
        } else if let profile = demuxer.dolbyVisionProfileString {
            if demuxer.dolbyVisionProfile == 8, demuxer.dolbyVisionCompatibilityId == 1 {
                video.dolbyVisionProfile = "Profile 8.1 (HDR10 Base)"
            } else if demuxer.dolbyVisionProfile == 8, demuxer.dolbyVisionCompatibilityId == 4 {
                video.dolbyVisionProfile = "Profile 8.4 (HLG Base)"
            } else {
                video.dolbyVisionProfile = "Profile \(profile)"
            }
        }
    }
}
