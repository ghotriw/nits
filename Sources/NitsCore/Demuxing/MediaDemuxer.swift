import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox
import os

public final class MediaDemuxer: @unchecked Sendable {
    public static let hdrMetadataAttachmentKey: String = "Nits.FrameHDRMetadata"
    /// Sample attachment set when the container had no PTS for the packet (AVI stores decode order
    /// only). The sample's PTS then falls back to its DTS; software decoders must not pass it on as
    /// a real PTS or B-frame reordering skews every presentation timestamp.
    public static let presentationTimeUnknownAttachmentKey: String = "Nits.PresentationTimeUnknown"
    /// Exact-seek target (seconds) on preroll samples. `DoNotDisplay` is decided from the sample's PTS, or
    /// its DTS without one, which is too early for reordered frames; and a frame-per-field deinterlacer's
    /// second field may already reach the target. A decoder that knows the real PTS of what it outputs
    /// should compare it against this instead.
    public static let exactSeekTargetAttachmentKey: String = "Nits.ExactSeekTarget"

    /// What packets are read from (`DemuxerInput`). Behind `lock`, but for its description.
    let input: any DemuxerInput
    var videoStreamIndex: Int = -1
    var audioStreamIndex: Int = -1
    public internal(set) var timebase: AVRational = AVRational(num: 1, den: 1000)
    public internal(set) var audioTimebase: AVRational = AVRational(num: 1, den: 1000)
    public internal(set) var codec: VideoCodec = .hevc
    public internal(set) var hasVideo: Bool = false
    public internal(set) var nominalFrameDuration: Double = 1.0 / 24.0
    /// Presentation time of the first picture, in seconds on the playback timeline. A file cut between keyframes
    /// starts its video up to a GOP after its audio and subtitles. Read from the first keyframe when the file opens;
    /// 0 when the opening scan doesn't reach it.
    public internal(set) var videoStartTime: Double = 0
    /// The stream is interlaced: it signals a field order (`field_order` TT / BB / TB / BT), it is standard
    /// definition DV, interlaced by format, or its first ProRes frame header says so where the container gives no
    /// field order (`ProResFrameHeader`). Frames may still be flagged interlaced
    /// individually when this is `false`.
    public internal(set) var isInterlaced: Bool = false
    public internal(set) var hasAudio: Bool = false
    public internal(set) var audioCodecId: AVCodecID = AV_CODEC_ID_NONE
    public internal(set) var audioChannels: Int = 0
    public internal(set) var audioSampleRate: Int = 0
    public struct AudioTrack: Sendable, Identifiable, Equatable {
        public let id: Int
        public let streamIndex: Int
        public let title: String
        public let language: String
        public let codecName: String
        public let channels: Int
        public let sampleRate: Int
        /// Flagged to play by default (`AV_DISPOSITION_DEFAULT`).
        public let isDefault: Bool
        /// An audio description of the picture, for viewers who can't see it (`AV_DISPOSITION_VISUAL_IMPAIRED`:
        /// HLS's `public.accessibility.describes-video`).
        public let describesVideo: Bool
        /// The audio file the track is in, when it isn't in the media itself (`PlaybackInputs`).
        public let externalURL: URL?

        init(
            id: Int, streamIndex: Int, title: String, language: String, codecName: String, channels: Int,
            sampleRate: Int, isDefault: Bool, describesVideo: Bool = false, externalURL: URL? = nil
        ) {
            self.id = id
            self.streamIndex = streamIndex
            self.title = title
            self.language = language
            self.codecName = codecName
            self.channels = channels
            self.sampleRate = sampleRate
            self.isDefault = isDefault
            self.describesVideo = describesVideo
            self.externalURL = externalURL
        }

        /// This track with what is given replaced: another id (`PlaybackInputs` numbers an added file's tracks apart
        /// from the media's) and file, or the stream of another HLS variant.
        func with(
            id: Int? = nil, streamIndex: Int? = nil, title: String? = nil, language: String? = nil,
            isDefault: Bool? = nil, externalURL: URL? = nil
        ) -> AudioTrack {
            AudioTrack(
                id: id ?? self.id, streamIndex: streamIndex ?? self.streamIndex, title: title ?? self.title,
                language: language ?? self.language, codecName: codecName, channels: channels, sampleRate: sampleRate,
                isDefault: isDefault ?? self.isDefault, describesVideo: describesVideo,
                externalURL: externalURL ?? self.externalURL)
        }
    }

    /// A variant of an adaptive stream: an HLS `EXT-X-STREAM-INF`, which FFmpeg exposes as a program.
    public struct StreamVariant: Sendable, Identifiable, Equatable {
        /// The program's id (`AVProgram.id`).
        public let id: Int
        /// Peak bits per second (`BANDWIDTH`).
        public let bandwidth: Int
        public let width: Int
        public let height: Int
        /// Whether playback can switch to it without rebuilding the decoders: the video codec and colour, and the
        /// audio, are those of the variant chosen on load. See `selectVariant(id:)`.
        public let isSwitchable: Bool
    }

    /// The variants of an HLS master playlist, highest bandwidth first; empty for anything else. Only the streams of
    /// `selectedVariantId` are read: the others are discarded, so FFmpeg doesn't download their segments.
    public internal(set) var variants: [StreamVariant] = []
    /// The variant whose pictures are being read: a switch changes it at its splice. Its own lock: `lock` is held
    /// through blocking reads.
    public var selectedVariantId: Int? { variantSelection.withLock { $0.selected } }
    let variantSelection = OSAllocatedUnfairLock(initialState: VariantSelection())
    /// Streams of each variant by its id.
    var variantStreams: [Int: VariantStreams] = [:]
    /// The switch being spliced. Written with `lock` and `queueLock` held, so either one reads it.
    var variantSwitch: VariantSwitch?
    /// The input was asked to close the variants not read before the first seek (`prepareFirstSeek`), once. Behind
    /// `lock` and `queueLock`.
    var firstSeekPrepared = false
    /// The pictures read from a timeline second on: of which variant, and as they are.
    public struct VariantChange: Sendable {
        public let variant: StreamVariant
        /// Where they start: the splice, the target of a seek, where reading is when a switch is given up.
        public let seconds: Double
        /// From the parameter sets (`formatDescription`): a variant FFmpeg didn't probe reports 0 × 0.
        public let width: Int
        public let height: Int
        public let sampleAspectRatio: RationalAspectRatio
        public let frameDuration: Double
    }

    /// Called on the reading thread when the pictures read come from another variant (at a switch's splice), after
    /// a seek and when a switch is given up. Set before reading starts.
    public var onVariantChanged: (@Sendable (VariantChange) -> Void)?

    /// The size of the pictures changes without a variant switch: the parameter sets in the stream change (the segment
    /// after an HLS discontinuity is in another encoding, an advertisement; a file of joined streams). The sample
    /// buffers from `seconds` on carry the new format description (`videoPacket(from:)`), which VideoToolbox's session
    /// follows; this tells the player the size the picture is drawn at.
    public struct VideoSizeChange: Sendable {
        /// Where the pictures of the new size start on the timeline.
        public let seconds: Double
        public let width: Int
        public let height: Int
        public let sampleAspectRatio: RationalAspectRatio
        /// Told where a seek lands, changed or not: the size from there on, which replaces what was told before (the
        /// changes past it are told again after it: read again, or from the packet cache).
        public var isLanding = false
    }

    /// Called on the reading thread where the size of the pictures read changes (see `VideoSizeChange`). Set before
    /// reading starts.
    public var onVideoSizeChanged: (@Sendable (VideoSizeChange) -> Void)?
    /// The parameter sets of the keyframe last read in a stream that carries them in band (Behind the lock the packet
    /// is read under): a keyframe with others starts a new description.
    var lastSeenParameterSets: VideoFormatDescriptionBuilder.ParameterSets?
    /// A slow seek was made: the first keyframe read tells the size it lands at, even when it is the size reported before.
    var reportsVideoSizeAtNextKeyframe = false
    /// Adaptive bitrate state (`MediaDemuxer+AdaptiveBitrate.swift`); set up by `startReadAhead` before the thread
    /// that uses it starts.
    var adaptiveBitrate = AdaptiveBitrateState()
    /// Replaces the configuration `startReadAhead` scales to its limit (tests). Set before it.
    var adaptiveBitrateConfig: AdaptiveBitrateLogic.Config?
    /// Whether a download that will not arrive in time is given up for a lower variant's (`requestAbandon`).
    var abandonsDownloads = MediaDemuxer.abandonsEnabled
    /// Tests only: a segment in flight is checked for giving up once this allows it, given the position (seconds handed
    /// out), so that a test's premise (the position inside the segment) does not depend on how late playback runs on a
    /// busy machine. Set before `startReadAhead`.
    var abandonCheckGate: (@Sendable (_ segment: InFlightSegment, _ position: Double) -> Bool)?
    /// Tests only: false leaves a give-up with nothing of its segment queued to cut at without the keyframes read
    /// (`expectedHoleCut`), so it joins the next segment, as with no history kept.
    var abandonExpectsKeyframes = true
    /// This demuxer's number in the log (`streamingName`): one log holds the lines of every stream open (windows,
    /// thumbnails), and tests running side by side.
    let logID = MediaDemuxer.logIDs.withLock { counter in
        counter += 1
        return counter
    }
    private static let logIDs = OSAllocatedUnfairLock(initialState: 0)
    /// What the input's reads transferred over the network (behind `lock`); nil for local media.
    var network: (any NetworkReadAccount)? { input.network }
    /// Decode timestamp of the latest picture `readPacket` handed on (video time base), behind `lock`.
    var lastVideoReadTime = Int64.min

    public internal(set) var audioTracks: [AudioTrack] = []
    public internal(set) var selectedAudioTrackIndex: Int = -1
    public internal(set) var audioExtraData: Data? = nil
    public internal(set) var embeddedArtworkData: Data? = nil
    public internal(set) var chapters: [MediaChapter] = []

    public internal(set) var subtitleTracks: [SubtitleTrack] = []
    public private(set) var selectedSubtitleTrackId: Int? = nil
    private static func makeTrackers() -> (main: LiveSubtitleTracker, secondary: LiveSubtitleTracker) {
        let stash = LiveSubtitleTracker.makeStash()
        return (
            LiveSubtitleTracker(stash: stash, ownsStash: true), LiveSubtitleTracker(stash: stash, ownsStash: false)
        )
    }
    private let trackers = MediaDemuxer.makeTrackers()
    var subtitleTracker: LiveSubtitleTracker { trackers.main }
    /// The second track shown with the selected one: collected from the same packets, kept in a tracker of its own.
    var secondarySubtitleTracker: LiveSubtitleTracker { trackers.secondary }
    /// Id of the second subtitle track, `nil` for none. Behind `queueLock`.
    private(set) var selectedSecondarySubtitleTrackId: Int? = nil
    public var liveSubtitleVersion: Int {
        subtitleTracker.version
    }

    /// Which of the two tracks shown at once a call is about.
    enum SubtitleSlot { case main, secondary }

    func tracker(_ slot: SubtitleSlot) -> LiveSubtitleTracker {
        slot == .main ? subtitleTracker : secondarySubtitleTracker
    }

    func liveSubtitleVersion(of slot: SubtitleSlot) -> Int { tracker(slot).version }
    /// Furthest timeline second read from the audio and video streams since the last seek (`-infinity` before any),
    /// `infinity` once the input has been read to its end. Its own lock: `lock` is held through blocking reads.
    let readAheadState = OSAllocatedUnfairLock(initialState: -Double.infinity)
    /// The window of a live HLS playlist, as the playlist last loaded tells (`publishLiveWindow`); `nil` for other
    /// media. Once the playlist ends the last window stays, with `hasEnded` set. Its own lock, as `readAheadState`:
    /// read from the main actor.
    let liveWindowState: OSAllocatedUnfairLock<LiveReport?>
    /// A live HLS stream: opened as a playlist that slides and has no end yet (it stays set once the playlist ends,
    /// `LiveWindow.hasEnded`). It has no duration (`durationSeconds` is 0); what can be seeked in is `liveWindow`.
    public internal(set) var isLive = false
    /// A live stream given as the segments of its past (`LiveHistory`): played as live, though its manifest is a static
    /// one the demuxer reads the end of, on a timeline from zero. Its window is told by the resolver, not by the format
    /// context (`publishLiveWindow`), and `streamTimeOrigin` is the stream's time at the timeline's zero.
    public internal(set) var liveHistory: LiveHistory?
    public var streamTimeOrigin: Double { liveHistory?.origin ?? 0 }
    public var liveWindow: LiveWindow? { liveReport?.window }
    /// `liveWindow` and when its playlist was loaded.
    public var liveReport: LiveReport? {
        liveWindowState.withLock { $0 }
    }
    /// Timeline second up to which packets have been read ahead of playback; see `readAheadState`.
    public var readAheadSeconds: Double {
        readAheadState.withLock { $0 }
    }
    var lastAudioPts: Int64 = -1
    public var currentAudioPtsSeconds: Double {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard lastAudioPts >= 0 && audioTimebase.den > 0 else { return 0 }
        return Double(lastAudioPts) * Double(audioTimebase.num) / Double(audioTimebase.den)
    }

    // Track selection runs on the main thread: it takes `queueLock` only, never the I/O lock the read-ahead thread
    // holds through network reads. What the reads do with the selection (the stream indexes, the subtitle tracker)
    // happens after `av_read_frame` returns, under `queueLock`; the streams' parameters don't change once opened.

    /// Reads what a variant switch rewrites at its splice on the reading thread (the stream description:
    /// `timebase`, `formatDescription`, `nominalFrameDuration`, `audioTimebase`, `audioTracks`, …) without racing it:
    /// the splice holds `queueLock`. Needed once reading ahead, from any thread; `body` must not call the demuxer's
    /// own locking methods.
    public func readingDescription<T>(_ body: (MediaDemuxer) -> T) -> T {
        queueLock.lock()
        defer { queueLock.unlock() }
        return body(self)
    }

    public func getAudioCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        audioDecoderInput()?.parameters
    }

    /// The selected audio stream's parameters with its time base, read together (`readingDescription`).
    public func audioDecoderInput() -> (parameters: UnsafePointer<AVCodecParameters>, timebase: AVRational)? {
        readingDescription { demuxer in
            guard demuxer.audioStreamIndex >= 0, let stream = demuxer.input.stream(demuxer.audioStreamIndex) else {
                return nil
            }
            return (UnsafePointer(stream.pointee.codecpar), demuxer.audioTimebase)
        }
    }

    public func getVideoCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        readingDescription { $0.videoCodecParameters }
    }

    /// Behind `queueLock` (`readingDescription`).
    var videoCodecParameters: UnsafePointer<AVCodecParameters>? {
        guard videoStreamIndex >= 0, let stream = input.stream(videoStreamIndex) else { return nil }
        return UnsafePointer(stream.pointee.codecpar)
    }

    /// Selects the audio track `trackId`, or none (`nil`), when the audio heard comes from another input: this one's
    /// audio packets are then dropped as read, and `isAudioEOF` holds.
    public func selectAudioTrack(trackId: Int?) {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let trackId else {
            audioStreamIndex = -1
            selectedAudioTrackIndex = -1
            targetAudioPts = -1
            lastAudioPts = -1
            audioQueue.removeAll()
            streamSelectionChanged = true
            return
        }
        guard let track = audioTracks.first(where: { $0.id == trackId }), let stream = input.stream(track.streamIndex)
        else { return }
        self.audioStreamIndex = track.streamIndex
        self.selectedAudioTrackIndex = track.id
        self.audioTimebase = stream.pointee.time_base
        self.audioCodecId = stream.pointee.codecpar.pointee.codec_id
        self.audioChannels = Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels)
        self.audioSampleRate = Int(stream.pointee.codecpar.pointee.sample_rate)
        if let ed = stream.pointee.codecpar.pointee.extradata, stream.pointee.codecpar.pointee.extradata_size > 0 {
            self.audioExtraData = Data(bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
        } else {
            self.audioExtraData = nil
        }
        if !hasVideo {
            self.timebase = self.audioTimebase
        }
        self.audioQueue.removeAll()
        streamSelectionChanged = true
    }

    /// Selects an embedded subtitle track by id (or nil to disable).
    public func selectSubtitleTrack(trackId: Int?) {
        queueLock.lock()
        defer { queueLock.unlock() }
        self.selectedSubtitleTrackId = trackId
        streamSelectionChanged = true
        if trackId != nil, !variants.isEmpty { selectionOutdatesCache = true }
        // Packets from where the reads are now on belong to the new track; what came before is for a window read.
        let readAhead = subtitleReadAhead(inVideo: isCaptionsInVideo(trackId))
        subtitleTracker.selectTrack(id: trackId, tracks: subtitleTracks, in: input, readAhead: readAhead)
    }

    /// The streams of the subtitle tracks selected (the second one too) that are read as packets, not closed captions.
    var selectedSubtitleStreamIndices: [Int] {
        [selectedSubtitleTrackId, selectedSecondarySubtitleTrackId].compactMap { id in
            id.flatMap { id in subtitleTracks.first { $0.id == id && $0.closedCaptionField == nil }?.streamIndex }
        }
    }

    /// Selects the second subtitle track (or nil), as `selectSubtitleTrack` does the first: its packets are collected as
    /// playback reads them.
    func selectSecondarySubtitleTrack(trackId: Int?) {
        queueLock.lock()
        defer { queueLock.unlock() }
        selectedSecondarySubtitleTrackId = trackId
        streamSelectionChanged = true
        if trackId != nil, !variants.isEmpty { selectionOutdatesCache = true }
        let readAhead = subtitleReadAhead(inVideo: isCaptionsInVideo(trackId))
        secondarySubtitleTracker.selectTrack(id: trackId, tracks: subtitleTracks, in: input, readAhead: readAhead)
    }

    /// Returns a SubtitleDocument with all cues collected in-band so far for the active subtitle track.
    /// Never touches the I/O lock, so it is safe to call from the main thread during network reads/seeks.
    public func getLiveSubtitleDocument() -> SubtitleDocument {
        subtitleTracker.getLiveSubtitleDocument()
    }

    func liveSubtitleDocument(of slot: SubtitleSlot) -> SubtitleDocument {
        tracker(slot).getLiveSubtitleDocument()
    }

    /// Identifies the current track selection and reading stretch for `mergeLiveSubtitles`, with the stream to read
    /// for it (`-1` for none) and, for closed captions, their field. Never touches the I/O lock, like
    /// `getLiveSubtitleDocument()`.
    var liveSubtitleSelection: (id: Int, streamIndex: Int, captionField: Int?, span: Int) {
        subtitleTracker.liveSubtitleSelection
    }

    func subtitleSelection(of slot: SubtitleSlot) -> (id: Int, streamIndex: Int, captionField: Int?, span: Int) {
        tracker(slot).liveSubtitleSelection
    }

    /// The part of the timeline a window read (`EmbeddedSubtitleReader.readSubtitles`) must read so the selected track
    /// is whole at `time` (track time: the subtitle delay applied), less what the lists hold already; `nil` when
    /// nothing is missing.
    func subtitleWindow(around time: Double, of slot: SubtitleSlot = .main) -> ClosedRange<Double>? {
        let readAhead = subtitleReadAhead(inVideo: tracker(slot).readsCaptionsInVideo)
        return tracker(slot).subtitleWindow(around: time, readAhead: readAhead)
    }

    /// Playback reads from `seconds` on, not from the seek target: a forward keyframe seek lands past it, and what it
    /// jumped over wasn't read. Called with the time a seek landed at.
    func noteSubtitleReadsStart(at seconds: Double) {
        subtitleTracker.noteSubtitleReadsStart(at: seconds)
        secondarySubtitleTracker.noteSubtitleReadsStart(at: seconds)
    }

    /// Adds the packets of a window read (`EmbeddedSubtitleReader.readSubtitles`) for the selection `selection` and
    /// reading stretch `span` to what playback collected, leaving out what is there already. Dropped (returning
    /// `false`) if another track was chosen or a seek started another stretch meanwhile.
    @discardableResult
    func mergeLiveSubtitles(
        _ packets: EmbeddedSubtitleReader.Packets, covering range: ClosedRange<Double>, selection: Int, span: Int,
        of slot: SubtitleSlot = .main
    ) -> Bool {
        tracker(slot).mergeLiveSubtitles(packets, covering: range, selection: selection, span: span)
    }

    /// The starts of each subtitle stream's packets by the file's own index (`EmbeddedSubtitleReader.readIndex`), once
    /// read: `[:]` from opening for a file whose index doesn't come from the file.
    private let subtitleIndexState = OSAllocatedUnfairLock<[Int: [Double]]?>(initialState: nil)

    /// Whether the file's index of subtitle streams is still to read (`storeSubtitleIndex`).
    var needsSubtitleIndex: Bool {
        subtitleIndexState.withLock { $0 == nil }
    }

    /// Takes what `EmbeddedSubtitleReader.readIndex` read.
    func storeSubtitleIndex(_ starts: [Int: [Double]]) {
        subtitleIndexState.withLock { $0 = starts.mapValues { $0.sorted() } }
    }

    /// The starts of the packets of subtitle stream `streamIndex` within `range` by the file's own index (Matroska
    /// Cues, an MP4 sample table), `nil` when it doesn't list them or isn't read yet: with none, a window read would
    /// find nothing. Never touches the I/O lock.
    func indexedSubtitleStarts(of streamIndex: Int, in range: ClosedRange<Double>) -> [Double]? {
        subtitleIndexState.withLock { $0?[streamIndex]?.filter { range.contains($0) } }
    }

    /// What playback read of the selected track before it was chosen, once (`LiveSubtitleTracker.takeStashedSubtitles`).
    /// Never touches the I/O lock.
    func takeStashedSubtitles(of slot: SubtitleSlot = .main) -> (
        snapshot: SubtitlePacketStash.Snapshot, selection: Int, span: Int
    )? {
        tracker(slot).takeStashedSubtitles()
    }

    /// Adds what a stash snapshot decoded to (`LiveSubtitleTracker.mergeStashed`).
    @discardableResult
    func mergeStashed(
        _ decoded: [EmbeddedSubtitleReader.Packets], of snapshot: SubtitlePacketStash.Snapshot, selection: Int,
        span: Int, of slot: SubtitleSlot = .main
    ) -> Bool {
        tracker(slot).mergeStashed(decoded, of: snapshot, selection: selection, span: span)
    }

    var audioQueue = DemuxerPacketBuffer<DemuxedAudioPacket>(indexesKeyframes: false)
    var videoQueue = DemuxerPacketBuffer<DemuxedVideoPacket>()
    /// The times of the latest video keyframes queued, apart from the packets: a live read-ahead keeps no history
    /// (`backBytes` 0), and a give-up with nothing queued to cut at places its cut by them (`expectedHoleCut`). Behind
    /// `queueLock`, as the queue.
    var keyframeTrail = KeyframeTrail()
    private let maxAudioQueueCount = 500
    private let maxVideoQueueCount = 180
    /// Bumped at a variant's splice (`spliceVariantVideo`): the packets read in between carry it
    /// (`VideoPacketFormat.variantGeneration`), which tells a cached seek whether it crosses one. New parameter sets within
    /// a variant don't bump it: the cache serves those like a single-variant stream's. Written with `queueLock` held.
    var variantGeneration = 0
    public internal(set) var formatDescription: CMVideoFormatDescription?
    public internal(set) var durationSeconds: Double = 0
    public internal(set) var width: Int = 0
    public internal(set) var height: Int = 0
    /// Sample Aspect Ratio (Pixel Aspect Ratio) from stream metadata (e.g. 720:959 or 1:1)
    public internal(set) var sampleAspectRatio: RationalAspectRatio = .square
    /// Effective Display Aspect Ratio (DAR) taking SAR into account: (width * sar.multiplier) / height
    public var displayAspectRatio: Double {
        RationalAspectRatio.computeDisplayAspectRatio(width: width, height: height, sar: sampleAspectRatio)
    }
    /// The static peak: MaxCLL, else the mastering display's; 1000 when the stream carries neither (or only zeros).
    public internal(set) var maxPeakNits: Float = 1000.0 {
        didSet { hasStaticPeak = true }
    }
    public internal(set) var maxFallNits: Float = 0.0
    /// Whether `maxPeakNits` comes from the stream rather than the default: a CLL block of 0 / 0 is no peak.
    public private(set) var hasStaticPeak = false
    public internal(set) var colorPrimaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2
    public internal(set) var transferFunction: CFString = kCVImageBufferTransferFunction_ITU_R_709_2
    public internal(set) var yCbCrMatrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    public internal(set) var isFullRange: Bool = false
    public internal(set) var chromaLocation: CFString = kCVImageBufferChromaLocation_Left
    public internal(set) var bitDepth: Int = 8
    public internal(set) var isDolbyVisionProfile5: Bool = false
    public internal(set) var dolbyVisionProfile: Int? = nil
    public internal(set) var dolbyVisionCompatibilityId: Int? = nil
    public internal(set) var dolbyVisionConfigData: Data? = nil
    public var dolbyVisionProfileString: String? {
        guard let p = dolbyVisionProfile else { return nil }
        if p == 8 {
            if let cid = dolbyVisionCompatibilityId {
                if cid == 1 { return "8.1" }
                if cid == 2 { return "8.2" }
                if cid == 4 { return "8.4" }
                return "8 (Compat \(cid))"
            }
            return "8.1"
        }
        if p == 5 { return "5" }
        if p == 7 { return "7" }
        if p == 9 { return "9" }
        return "\(p)"
    }
    public internal(set) var isAnnexBStream: Bool = false
    public var isHDR: Bool {
        if isDolbyVisionProfile5 { return true }
        if let p = dolbyVisionProfile {
            // Profile 8.2 has an SDR (BT.709) base layer; Profile 8.1 (PQ) and 8.4 (HLG) are HDR
            if p == 8 {
                if dolbyVisionCompatibilityId == 2 { return false }
                return true
            }
            if p == 5 || p == 7 { return true }
            if p == 9 { return false }  // Profile 9 is 8-bit AVC / SDR base layer
        }
        if transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            || transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG
        {
            return true
        }
        // BT.2020 with an SDR transfer is wide-gamut SDR: the system shows it as it is.
        return false
    }
    var masteringDisplay: Data?
    var contentLightLevel: Data?
    /// CEA-608 fields the first pictures carry captions in (`ClosedCaptions.fields(of:)`), found while opening.
    var closedCaptionFields: Set<Int> = []

    /// Cancels this demuxer's blocking I/O; share one across demuxers to cancel a whole load.
    public typealias InterruptContext = FFmpegInterrupt

    let interruptContext: InterruptContext
    private let ownsInterruptContext: Bool
    /// I/O lock is held across blocking `av_read_frame` / `av_seek_frame` calls (hundreds of ms on
    /// network streams); readers on the main thread must never contend with it. Take it with `lockIO()`, which lets
    /// the read-ahead thread step aside.
    /// Lock order: `lock` -> `queueLock` -> the lock inside `subtitleTracker` (never the reverse).
    let lock = OSAllocatedUnfairLock()
    /// Guards the packet queues and what goes with them (`targetPts`, `targetAudioPts`, `lastAudioPts`,
    /// `isEOFInternal` and the read-ahead state). Held only briefly: while reading ahead, consumers take packets
    /// under it alone, and the read-ahead thread releases it during `av_read_frame`.
    let queueLock = OSAllocatedUnfairLock()
    /// Reading on demand (not ahead), the input has been read to its end (or an error), until a seek; reading ahead,
    /// `readAheadEnded` tells it.
    var inputEndedOnDemand: Bool = false
    /// Behind `queueLock`.
    var inputEnded: Bool { readsAhead ? readAheadEnded : inputEndedOnDemand }
    /// Every video packet of the input has been taken (or it has no video).
    public var isVideoEOF: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return videoStreamIndex < 0 || (inputEnded && videoQueue.isEmpty)
    }
    /// Every packet of the selected audio track has been taken (or none is selected).
    public var isAudioEOF: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return audioStreamIndex < 0 || (inputEnded && audioQueue.isEmpty)
    }
    /// Reading ahead, no video packet is queued and more are to come: the input is behind with the pictures (a slow
    /// network), not the decoder. Never while reading on demand, which reads as the video feeder asks.
    var isVideoReadAheadDry: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return readsAhead && videoStreamIndex >= 0 && videoQueue.isEmpty && !readAheadEnded
    }
    /// Both `isVideoEOF` and `isAudioEOF`, read together: with nothing selected (no picture, the audio from another
    /// input) there is nothing left to come.
    public var isEOF: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        let isVideoDone = videoStreamIndex < 0 || (inputEnded && videoQueue.isEmpty)
        let isAudioDone = audioStreamIndex < 0 || (inputEnded && audioQueue.isEmpty)
        return isVideoDone && isAudioDone
    }

    // Read-ahead (`MediaDemuxer+ReadAhead.swift`), behind `queueLock`.
    /// A thread reads packets ahead into the queues; consumers only take them.
    public internal(set) var readsAhead = false
    /// Read over the network (`MediaURL.isNetworkSource`): a URL, or a saved HLS manifest of network media.
    public var isNetworkSource: Bool { input.isNetworkSource }

    /// A second demuxer can read the source by its address (`DemuxerInputTraits.opensAsFile`).
    var canOpenAsFile: Bool { input.traits.opensAsFile }
    /// How to read subtitle stream `index` outside playback when the input is an HLS stream (a rendition of a VOD
    /// playlist), which a second demuxer can't open as a file; nil for any other.
    func hlsSubtitleSource(streamIndex index: Int) -> HLSSubtitleWindowSource? {
        (input as? HLSInput)?.subtitleWindowSource(forStream: index)
    }
    /// A track was selected since the last read: the next one applies it (`applyStreamSelection`).
    var streamSelectionChanged = false
    /// A subtitle rendition of an HLS stream was selected after the packets in the queues were read: it is a playlist of
    /// its own, read only while selected, so they lack it, and a seek in them would show it from the read position on
    /// (see `SubtitleController.rereadForRendition`). Unlike `streamSelectionChanged` the read-ahead thread does not
    /// take it back: only a seek that reads the input again (and clears the queues) does. An audio track needs none:
    /// the audio queue is emptied at its selection, and a seek the audio left does not cover is a slow one.
    var selectionOutdatesCache = false
    /// The read-ahead thread stopped at the end of the input or an error, until a seek.
    var readAheadEnded = false
    /// Whether the read-ahead thread stopped specifically because it reached EOF (not an error).
    var readAheadHitEOF = false
    /// Timeline second the packets read so far reach (the end of the furthest packet of either stream). Behind `queueLock`.
    var cachedFrontierSeconds: Double {
        var seconds = 0.0
        if videoQueue.maxPacketEndPTS != Int64.min, timebase.den > 0 {
            seconds = Double(videoQueue.maxPacketEndPTS) * Double(timebase.num) / Double(timebase.den)
        }
        if audioQueue.maxPacketEndPTS != Int64.min, audioTimebase.den > 0 {
            seconds = max(
                seconds, Double(audioQueue.maxPacketEndPTS) * Double(audioTimebase.num) / Double(audioTimebase.den))
        }
        return seconds
    }
    /// Timeline second of the packets last taken from the queues: the read-ahead target is measured from it.
    var consumedSeconds: Double {
        get { consumedState.withLock { $0 } }
        set { consumedState.withLock { $0 = newValue } }
    }
    /// Behind its own lock as well, for the callback of a download that waits with `queueLock` released
    /// (`noteSegmentInFlight`).
    private let consumedState = OSAllocatedUnfairLock(initialState: 0.0)
    var readAheadLimits = ReadAheadLimits()
    /// Consumers waiting in `nextVideoSample(waitingForReadAhead:)` for `packetArrival`.
    var packetWaiters = 0
    let packetArrival = DispatchSemaphore(value: 0)
    /// Wakes the read-ahead thread: a seek, a stop, a caller of `lockIO()`.
    let readAheadWake = DispatchSemaphore(value: 0)
    let readAheadControl = OSAllocatedUnfairLock(initialState: ReadAheadControl())

    /// Returns human-readable error description from FFmpeg av_strerror.
    public static func ffmpegErrorDescription(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let res = av_strerror(code, &buffer, 256)
        if res == 0 {
            return buffer.withUnsafeBufferPointer { ptr in
                String(cString: ptr.baseAddress!)
            }
        }
        return "FFmpeg error (\(code))"
    }

    public convenience init?(url: String) {
        self.init(url: url, headers: [:], interruptContext: nil)
    }

    /// Opens `url`: with `HLSInput` when it is an HLS playlist, else with FFmpeg (`FFmpegInput`).
    ///
    /// - Parameters:
    ///   - httpRequestSize: What a network input's HTTP requests ask for (`MediaLoadRequest.httpRequestSize`).
    ///   - audioOnly: Reads the input's audio streams only, every other one discarded (pictures, cover art,
    ///     subtitles, closed captions): an audio track of other media, whose own picture nobody would take.
    public convenience init?(
        url: String,
        headers: [String: String] = [:],
        httpRequestSize: Int? = nil,
        interruptContext: InterruptContext? = nil,
        audioOnly: Bool = false,
        liveHistory: LiveHistory? = nil
    ) {
        let interrupt = interruptContext ?? InterruptContext()
        let windowState = OSAllocatedUnfairLock<LiveReport?>(initialState: nil)
        // HLS: Nits' own client (FFmpeg's HLS demuxer is not built). A playlist is known by its name; one under another
        // name is what FFmpeg fails to open (below).
        if liveHistory == nil, HLSInput.applies(to: url) {
            guard let input = HLSInput(url: url, headers: headers, interrupt: interrupt) else {
                if interruptContext == nil { interrupt.cancel() }
                return nil
            }
            self.init(
                input: input, interruptContext: interrupt, ownsInterruptContext: interruptContext == nil,
                audioOnly: audioOnly, liveHistory: nil, liveWindowState: windowState)
            return
        }
        let origin = liveHistory?.origin ?? 0
        let opened = FFmpegInput(
            url: url, headers: headers, httpRequestSize: httpRequestSize, interrupt: interrupt,
            liveHistory: liveHistory,
            onLiveHistoryChange: { change in
                windowState.withLock { state in
                    guard let report = state else { return }
                    state = Self.applying(change, to: report, origin: origin, now: .now)
                }
            })
        // A playlist under a name that tells none: FFmpeg, with no HLS demuxer, took it for no format at all
        // (`AVERROR_INVALIDDATA`), or for text (`tty`, which takes `.txt` and any small text).
        let mayBePlaylist = opened.map(\.isTextFormat) ?? (interrupt.lastError?.code == Self.averrorInvalidData)
        if liveHistory == nil, mayBePlaylist, HLSInput.sniffsAsPlaylist(url, headers: headers, interrupt: interrupt) {
            // It is a playlist: a failure to open it as one is the answer, not a "video" of its text.
            opened?.close()
            guard let input = HLSInput(url: url, headers: headers, interrupt: interrupt) else {
                if interruptContext == nil { interrupt.cancel() }
                return nil
            }
            self.init(
                input: input, interruptContext: interrupt, ownsInterruptContext: interruptContext == nil,
                audioOnly: audioOnly, liveHistory: nil, liveWindowState: windowState)
            return
        }
        guard let input = opened else {
            // What the attempt started (a transport's requests) gives way, as the demuxer's would at its end.
            if interruptContext == nil { interrupt.cancel() }
            return nil
        }
        self.init(
            input: input, interruptContext: interrupt, ownsInterruptContext: interruptContext == nil,
            audioOnly: audioOnly, liveHistory: liveHistory, liveWindowState: windowState)
    }

    /// Reads `input`, opened with `interruptContext`. Nil when it has neither a picture nor a sound to play.
    init?(
        input: any DemuxerInput, interruptContext: InterruptContext, ownsInterruptContext: Bool, audioOnly: Bool,
        liveHistory: LiveHistory?, liveWindowState: OSAllocatedUnfairLock<LiveReport?>
    ) {
        self.input = input
        self.interruptContext = interruptContext
        self.ownsInterruptContext = ownsInterruptContext
        self.liveHistory = liveHistory
        self.liveWindowState = liveWindowState
        // The opening scan of the first packets (`extractVideoFormatDescription`) is part of the opening.
        defer {
            input.finishOpening()
            input.observeSegments { [weak self] segment in self?.noteSegmentInFlight(segment) }
        }

        // FFmpeg indexes what its seeks read past `readPacket` elsewhere (the MPEG-TS timestamp search, the generic
        // seek): only the index of Matroska and MP4 comes from the file.
        if !input.traits.hasIndex { storeSubtitleIndex([:]) }

        // An audio-only input plays no variants: their selection would enable a picture again.
        let streamsToRead = audioOnly ? nil : discoverVariants()
        for i in 0..<input.streamCount {
            guard let stream = input.stream(i) else { continue }
            let codecType = stream.pointee.codecpar.pointee.codec_type
            if let streamsToRead, !streamsToRead.contains(i) {
                input.setReading(false, stream: i)
                continue
            }
            if audioOnly, codecType != AVMEDIA_TYPE_AUDIO {
                input.setReading(false, stream: i)
                continue
            }
            let isAttachedPic = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            if codecType == AVMEDIA_TYPE_VIDEO && !isAttachedPic && self.videoStreamIndex < 0,
                let detectedCodec = VideoCodec.from(parameters: stream.pointee.codecpar)
            {
                configureVideoStream(stream, index: i, codec: detectedCodec)
            } else if codecType == AVMEDIA_TYPE_AUDIO {
                registerAudioTrack(stream, index: i)
            } else if codecType == AVMEDIA_TYPE_SUBTITLE {
                registerSubtitleTrack(stream, index: i)
            }

            // Extract embedded artwork (cover art / attached picture) if present
            if isAttachedPic, self.embeddedArtworkData == nil {
                let attachedPic = stream.pointee.attached_pic
                if let picData = attachedPic.data, attachedPic.size > 0 {
                    self.embeddedArtworkData = Data(bytes: picData, count: Int(attachedPic.size))
                }
            }
        }

        // HLS: the renditions of the tracks selected only (`applyStreamSelection`).
        applyStreamSelection()
        if videoStreamIndex >= 0 {
            self.hasVideo = true
            self.formatDescription = extractVideoFormatDescription()
            registerClosedCaptionTracks()
        } else if audioStreamIndex >= 0, let stream = input.stream(audioStreamIndex) {
            self.hasVideo = false
            self.timebase = self.audioTimebase
            if stream.pointee.duration > 0 {
                self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
            } else if input.durationSeconds > 0 {
                self.durationSeconds = input.durationSeconds
            }
        } else {
            return nil
        }

        if input.isLivePlaylist {
            isLive = true
            durationSeconds = 0
            publishLiveWindow()
        } else if let liveHistory {
            isLive = true
            durationSeconds = 0
            // The window starts at the timeline's zero; `hasSlid` as the server's oldest segments expire as time goes.
            let window = LiveWindow(start: 0, end: liveHistory.end - liveHistory.origin, hasSlid: true)
            liveWindowState.withLock { $0 = LiveReport(window: window, loadedAt: .now) }
        }
        self.chapters = MediaChapter.normalized(input.chapters, duration: durationSeconds)
    }

    /// `AVERROR_INVALIDDATA` (`-MKTAG('I', 'N', 'D', 'A')`): the input is of no format FFmpeg knows.
    static let averrorInvalidData: Int32 = -0x4144_4E49

    /// `AVERROR_EOF` (`-MKTAG('E', 'O', 'F', ' ')`); the macro does not import into Swift.
    static let averrorEOF: Int32 = -0x2046_4F45

    /// The next packet of the input, with timestamps on the zero-based timeline. Records how far audio and video have
    /// been read (`readAheadSeconds`), and hands subtitle packets to `subtitleTracker`, as playback takes embedded
    /// subtitles in band: the main way for every source. A network source is opened again only to read its index and
    /// the windows that index tells of; a server with a single connection fails the index read, and no window is read.
    ///
    /// Called with `lock` and, but at opening, `queueLock` held. `releasingQueueLock` (the read-ahead thread) lets
    /// consumers take packets while the input reads.
    func readPacket(_ pkt: inout AVPacket, releasingQueueLock: Bool = false) -> Int32 {
        beginRequestedVariantSwitch()
        applyChangedStreamSelection()
        while true {
            if releasingQueueLock { queueLock.unlock() }
            let ret = input.read(&pkt)
            if releasingQueueLock { queueLock.lock() }
            // A seek waiting for the input interrupted the read (`lockIO(yielding:)`): FFmpeg may report it as the end of the
            // input, which is none, so nothing below (the end of the input's bookkeeping) is done for it.
            if ret < 0, interruptContext.isYieldingIO, !interruptContext.shouldAbort { return ret }
            // A download given up for another's interrupted the read (`requestAbandon`): it is no end, nor an error, nor a
            // measure of the network. The switch is made, between packets, and the read goes on in the variant it joins.
            if ret == HTTPSessionInput.averrorExit, adaptiveBitrate.pendingAbandon != nil, !interruptContext.shouldAbort
            {
                _ = network?.transferMeter?.take()
                beginRequestedVariantSwitch()
                continue
            }
            // The playlist is reloaded inside the read: the window it tells moved.
            if isLive, liveHistory == nil { publishLiveWindow() }
            // The variant switched to was described by its first read, inside this one.
            let givenUp = variantSwitch == nil ? [] : verifyVariantSwitchTarget()
            if ret >= 0 {
                if givenUp.contains(Int(pkt.stream_index)) {
                    av_packet_unref(&pkt)
                    continue
                }
                if variantSwitch != nil, !admitDuringVariantSwitch(&pkt) {
                    av_packet_unref(&pkt)
                    continue
                }
                if adaptiveBitrate.restart != nil, !admitRestarted(&pkt) {
                    av_packet_unref(&pkt)
                    continue
                }
                if pkt.stream_index == videoStreamIndex {
                    lastVideoReadTime = pkt.dts != Int64.min ? pkt.dts : pkt.pts
                }
                recordReadAhead(pkt)
                subtitleTracker.readPacket(&pkt, in: input)
                secondarySubtitleTracker.readPacket(&pkt, in: input)
            } else if ret == Self.averrorEOF {
                endVariantSwitchAtEOF()
                adaptiveBitrate.restart = nil
                readAheadState.withLock { $0 = .infinity }
                subtitleTracker.finishCaptions(video: false)
            }
            return ret
        }
    }

    /// End of a packet (`pts` plus a positive `duration`), saturating instead of trapping on the corrupt timestamps
    /// near `Int64.max` a damaged stream can carry.
    static func packetEnd(pts: Int64, duration: Int64) -> Int64 {
        let (end, overflow) = pts.addingReportingOverflow(max(duration, 0))
        return overflow ? .max : end
    }

    func recordReadAhead(_ pkt: AVPacket) {
        guard pkt.stream_index == videoStreamIndex || pkt.stream_index == audioStreamIndex,
            let stream = input.stream(Int(pkt.stream_index))
        else { return }
        let timebase = stream.pointee.time_base
        let start = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        guard start != Int64.min, timebase.num > 0, timebase.den > 0 else { return }
        let end =
            Double(Self.packetEnd(pts: start, duration: pkt.duration)) * Double(timebase.num) / Double(timebase.den)
        readAheadState.withLock { $0 = max($0, end) }
    }

    var targetPts: Int64 = -1
    var targetAudioPts: Int64 = -1

    /// The next video sample. While reading ahead it comes from the queue: with `waitingForReadAhead` (synchronous
    /// pumps on `seekQueue`) this waits for the read-ahead thread when the queue is empty; without (the video feeder,
    /// which sleeps cooperatively) it returns nil at once, and `isEOF` tells the end.
    public func nextVideoSample(waitingForReadAhead: Bool = true) -> CMSampleBuffer? {
        if let queued = nextReadAheadVideoSample(waiting: waitingForReadAhead) { return queued }
        lockIO()
        defer { lock.unlock() }
        queueLock.lock()
        defer { queueLock.unlock() }

        // Drain videoQueue first if audio reading buffered video packets
        while let vp = takeQueuedVideo() {
            if let sample = createVideoSample(from: vp) {
                return sample
            }
        }

        guard formatDescription != nil else { return nil }

        var pkt = AVPacket()
        while readPacket(&pkt, releasingQueueLock: true) >= 0 {
            if pkt.stream_index == videoStreamIndex {
                // Through the queue, behind what the read itself queued (the pictures a variant switch held back).
                videoQueue.append(videoPacket(from: pkt))
                av_packet_unref(&pkt)
                while let vp = takeQueuedVideo() {
                    if let sample = createVideoSample(from: vp) { return sample }
                }
            } else if pkt.stream_index == audioStreamIndex {
                // Buffer audio packet for Stage 2 audio pipeline
                audioQueue.append(DemuxedAudioPacket(pkt))
                av_packet_unref(&pkt)
            } else {
                av_packet_unref(&pkt)
            }
        }
        // The read loop ends at the end of the input (or an error); what is queued (the pictures a switch held until
        // then) is still to be taken.
        // The input has ended before the last of them is taken: the caption decoder is flushed with it (`takeQueuedVideo`).
        inputEndedOnDemand = true
        while let vp = takeQueuedVideo() {
            if let sample = createVideoSample(from: vp) { return sample }
        }
        return nil
    }

    /// Retrieves next queued audio packet if available, or pumps stream until one arrives. While reading ahead it
    /// only takes from the queue, and returns nil at once when it is empty (`isEOF` tells the end).
    public func nextAudioPacket() -> DemuxedAudioPacket? {
        queueLock.lock()
        if readsAhead {
            defer { queueLock.unlock() }
            let packet = popQueuedAudio()
            if let packet, !hasVideo, audioTimebase.den > 0 {
                consumedSeconds = Double(packet.pts) * Double(audioTimebase.num) / Double(audioTimebase.den)
            }
            return packet
        }
        queueLock.unlock()
        lockIO()
        defer { lock.unlock() }
        queueLock.lock()
        defer { queueLock.unlock() }

        if let packet = popQueuedAudio() { return packet }

        // If audio queue is empty, pump demuxer to find the next audio packet
        guard audioStreamIndex >= 0 else { return nil }

        // Backpressure check: if videoQueue is already large, don't read endlessly ahead
        if videoQueue.count >= maxVideoQueueCount {
            return nil
        }

        var pkt = AVPacket()
        while readPacket(&pkt, releasingQueueLock: true) >= 0 {
            if pkt.stream_index == audioStreamIndex {
                let pktPts = pkt.pts
                let pktDuration = pkt.duration
                if targetAudioPts >= 0 {
                    let packetEndPts = Self.packetEnd(pts: pktPts, duration: pktDuration)
                    if packetEndPts < targetAudioPts {
                        av_packet_unref(&pkt)
                        continue
                    }
                    targetAudioPts = -1
                }
                let audioPacket = DemuxedAudioPacket(pkt)
                self.lastAudioPts = pktPts
                av_packet_unref(&pkt)
                return audioPacket
            } else if pkt.stream_index == videoStreamIndex {
                // Symmetric buffering: preserve ALL video packets without dropping GOP frames!
                let packet = videoPacket(from: pkt)
                videoQueue.append(packet)
                av_packet_unref(&pkt)
            } else {
                av_packet_unref(&pkt)
            }
        }
        // The read loop ends at the end of the input (or an error); what is queued is still to be taken.
        inputEndedOnDemand = true
        return nil
    }

    /// The first queued audio packet that ends at or after `targetAudioPts`. Behind `queueLock`.
    private func popQueuedAudio() -> DemuxedAudioPacket? {
        while let p = audioQueue.popFirst() {
            pruneAudioQueueIfNeeded()
            if targetAudioPts >= 0 {
                let packetEndPts = p.packetEnd
                if packetEndPts < targetAudioPts {
                    continue
                }
                targetAudioPts = -1
            }
            self.lastAudioPts = p.pts
            return p
        }
        return nil
    }

    public func cancel() {
        stopReadAhead()
        interruptContext.cancel()
    }

    deinit {
        stopReadAhead()
        if ownsInterruptContext {
            interruptContext.cancel()
        }
        lockIO()
        defer { lock.unlock() }
        input.close()
    }
}
