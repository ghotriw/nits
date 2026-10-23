import Foundation
import Observation
import os
import simd

/// What `ToneMapController` needs of the player it tone-maps for; `PlayerEngine` is one, held weakly.
@MainActor
protocol ToneMapHost: AnyObject {
    var isPlaying: Bool { get }
    nonisolated var activeRenderMode: RenderMode { get }
}

/// Tone mapping of the Metal path on an SDR display: the user's adjustments, the reference white adapted to the
/// media's luminance, and the per-frame Dolby Vision curve (L1, optional L2 trims) written to the renderer's uniforms.
/// The player tells it when media loads (`mediaDidLoad`), when it goes (`reset`), when the render mode changes and,
/// from the display link, each frame tone-mapped (`applyFrame`).
@MainActor
@Observable
public final class ToneMapController {
    /// How a frame was tone-mapped: by the BT.2390 base curve alone, or with what of its Dolby Vision RPU.
    public struct Mode: Equatable, Sendable {
        public var usesL1 = false
        public var usesL2Trim = false
        /// Whether the RPU's curves reshaped the Profile 5 picture.
        public var usesReshaping = false

        /// The render mode name the performance monitor shows.
        public var name: String {
            let parts = [usesReshaping ? "Reshaping" : nil, usesL1 ? "L1" : nil, usesL2Trim ? "L2 Trim" : nil]
                .compactMap { $0 }
            return parts.isEmpty ? "Metal SDR" : "Metal SDR (DoVi \(parts.joined(separator: " + ")))"
        }
    }

    /// What `applyFrame` reads and moves on the display link, behind `frameState`.
    struct FrameState {
        /// The media's static peak, which L1 moves from.
        var basePeakNits: Float = 1000.0
        var smoothedPeakNits: Float = 1000.0
        var smoothedTargetNits: Float = ToneMapController.referenceWhiteNits
        var targetNitsScale: Float = 1.0
        /// The media has no static peak, and no RPU has set one yet (`applyFrame`).
        var awaitsSourcePeak = false
        var appliesTrims = false
        /// How the last frame was tone-mapped; a frame without RPU keeps it.
        var lastMode = Mode()
        /// RPU of the last tone-mapped frame, to re-render it when `appliesTrims` changes while paused.
        var lastDoviMetadata: DolbyVisionFrameMetadata?
        /// Profile 5 reshaping and colour matrices, which RPUs update.
        var reshaper = DolbyVisionReshaper()
    }

    /// ITU-R BT.2408 reference white: the target for high-peak HDR, which the adaptation lowers from.
    public nonisolated static let referenceWhiteNits: Float = 203.0
    /// Shadow lift applied to a media with a low MaxFALL while the user sets none.
    nonisolated static let lowFallShadowLift: Float = 0.008

    public var exposure: Float = 1.0 {
        didSet {
            let exposure = exposure
            renderer?.updateUniforms { $0.outputExposure = exposure }
        }
    }
    /// The user's shadow lift, 0 for none; `nil` leaves the one the media asks for (`appliedShadowLift`).
    public var shadowLift: Float? {
        didSet { updateShadowLiftUniform() }
    }
    /// Shadow lift the shader applies: the user's, else the one the media's luminance asks for.
    public var appliedShadowLift: Float { shadowLift ?? mediaShadowLift }
    /// Set on load for a media with a low MaxFALL, cleared by `reset`.
    private var mediaShadowLift: Float = 0.0 {
        didSet { updateShadowLiftUniform() }
    }
    /// Multiplier of the content-adapted reference white (0.5 ... 2.0 in UI, 0.1 ... 4.0 here).
    public var targetNitsScale: Float = 1.0 {
        didSet {
            let clamped = max(0.1, min(4.0, targetNitsScale))
            if targetNitsScale != clamped {
                targetNitsScale = clamped
                return
            }
            // The same value again (a configuration re-applied) must not restart the smoothed Dolby Vision curve.
            guard clamped != oldValue else { return }
            frameState.withLock { $0.targetNitsScale = clamped }
            updateTargetNits()
        }
    }
    /// Reference white adapted to the media's peak and MaxFALL (e.g. 203 for 1000-nit content, ~116 for a dim one).
    public private(set) var baseTargetNits: Float = ToneMapController.referenceWhiteNits
    /// `baseTargetNits` scaled by `targetNitsScale`: the target of the static curve.
    public private(set) var targetNits: Float = ToneMapController.referenceWhiteNits
    public var sharpness: Float = 0.5 {
        didSet {
            let sharpness = sharpness
            renderer?.updateUniforms { $0.outputSharpness = sharpness }
        }
    }
    /// Whether Dolby Vision L2 trims are applied on top of BT.2390 (see `PlayerConfiguration.applyDolbyVisionTrims`).
    /// A paused frame is re-rendered right away, so the change can be compared on the same frame.
    public var applyDolbyVisionTrims: Bool = false {
        didSet {
            guard applyDolbyVisionTrims != oldValue else { return }
            let enabled = applyDolbyVisionTrims
            let lastMetadata = frameState.withLock {
                $0.appliesTrims = enabled
                return $0.lastDoviMetadata
            }
            guard let host, !host.isPlaying, host.activeRenderMode == .metalToneMap, let lastMetadata else { return }
            _ = applyFrame(doviMetadata: lastMetadata)
            renderer?.redrawLastFrame()
        }
    }

    @ObservationIgnored weak var host: (any ToneMapHost)?
    @ObservationIgnored nonisolated let renderer: MetalVideoRenderer?
    @ObservationIgnored nonisolated let monitor: PlayerPerformanceMonitor
    @ObservationIgnored nonisolated let frameState = OSAllocatedUnfairLock(initialState: FrameState())

    /// A controller writing to `renderer`'s uniforms (none: settings only, e.g. a host's own engine) and reporting
    /// to `monitor`.
    public init(renderer: MetalVideoRenderer?, monitor: PlayerPerformanceMonitor = .shared) {
        self.renderer = renderer
        self.monitor = monitor
    }

    /// Takes the tone-mapping settings of `configuration` that differ from `previous` (all without one): a setting
    /// changed from the menu or the quick settings, which the configuration doesn't record, stays when another changes.
    func apply(_ configuration: PlayerConfiguration, previous: PlayerConfiguration? = nil) {
        if configuration.targetNitsScale != previous?.targetNitsScale {
            targetNitsScale = configuration.targetNitsScale
        }
        if configuration.sharpness != previous?.sharpness {
            sharpness = configuration.sharpness
        }
        if configuration.applyDolbyVisionTrims != previous?.applyDolbyVisionTrims {
            applyDolbyVisionTrims = configuration.applyDolbyVisionTrims
        }
    }

    /// Forgets the media's luminance and its last frame; the user's adjustments stay.
    func reset() {
        mediaShadowLift = 0
        baseTargetNits = Self.referenceWhiteNits
        updateTargetNits()
        frameState.withLock {
            $0.basePeakNits = 1000.0
            $0.smoothedPeakNits = 1000.0
            $0.awaitsSourcePeak = false
            $0.lastMode = Mode()
            $0.lastDoviMetadata = nil
            $0.reshaper.reset()
        }
        renderer?.updateUniforms { uniforms in
            uniforms.doviReshaping = ToneMapUniforms.DolbyVisionReshaping()
        }
        monitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(mode: .none, peakNits: 0, targetNits: targetNits))
    }

    /// Adapts the curve to the picture of media `demuxer` has just opened: its luminance and its colour.
    func mediaDidLoad(_ demuxer: MediaDemuxer) {
        let hasStatic = demuxer.hasStaticPeak
        let peakNits = demuxer.maxPeakNits
        adapt(toPeakNits: peakNits, fallNits: demuxer.maxFallNits, hasStaticPeak: hasStatic)
        let target = targetNits

        let isDolbyVisionProfile5 = demuxer.isDolbyVisionProfile5
        let (primaries, transferFunction) = Self.shaderColor(
            primaries: demuxer.colorPrimaries, transferFunction: demuxer.transferFunction,
            isDolbyVisionProfile5: isDolbyVisionProfile5)
        let bitDepth = UInt32(demuxer.bitDepth)
        let isFullRange = demuxer.isFullRange
        frameState.withLock { $0.reshaper.reset(isProfile5: isDolbyVisionProfile5) }
        renderer?.updateUniforms { uniforms in
            uniforms.colorPrimaries = primaries.shaderIndex
            uniforms.transferFunction = transferFunction.shaderIndex
            uniforms.bitDepth = bitDepth
            uniforms.isFullRange = isFullRange ? 1 : 0
            if isDolbyVisionProfile5 {
                uniforms.colorSpaceMode = 2  // Dolby Vision IPT / ICtCp
            } else if primaries == .bt709 {
                uniforms.colorSpaceMode = 1  // BT.709
            } else {
                uniforms.colorSpaceMode = 0  // Standard BT.2020 YCbCr
            }
            uniforms.doviReshaping = ToneMapUniforms.DolbyVisionReshaping()
        }

        let mode: PlayerPerformanceMonitor.ToneMapEngineMode
        if host?.activeRenderMode == .system {
            mode = .appleXDR
        } else if isDolbyVisionProfile5 || demuxer.dolbyVisionProfile != nil {
            mode = .doviL1Auto
        } else if demuxer.isHDR {
            mode = .bt2390
        } else {
            mode = .directSDR
        }
        monitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(mode: mode, peakNits: peakNits, targetNits: target))
    }

    /// The primaries and transfer function the shader decodes the picture with: the stream's, except for Dolby Vision
    /// Profile 5, which is IPT-PQ-c2 (PQ, BT.2020 once decoded) whatever its VUI says (often unspecified, read as BT.709).
    nonisolated static func shaderColor(
        primaries: CFString, transferFunction: CFString, isDolbyVisionProfile5: Bool
    ) -> (ColorPrimariesClass, TransferFunctionClass) {
        isDolbyVisionProfile5
            ? (.bt2020, .pq) : (ColorPrimariesClass(primaries), TransferFunctionClass(transferFunction))
    }

    /// Adapts the reference white and the shadow lift to the media's static luminance (MaxCLL or the mastering
    /// peak, MaxFALL; 0 for unknown), which L1 then moves from. Without a static peak (`hasStaticPeak` false,
    /// `peakNits` a default) the first RPU's source display peak stands in for it, unless L1 came first.
    func adapt(toPeakNits peakNits: Float, fallNits: Float, hasStaticPeak: Bool) {
        baseTargetNits = Self.adaptiveTargetNits(maxPeakNits: peakNits, maxFallNits: fallNits)
        mediaShadowLift = fallNits > 0 && fallNits < 80.0 ? Self.lowFallShadowLift : 0
        updateTargetNits()
        frameState.withLock {
            $0.basePeakNits = peakNits
            $0.smoothedPeakNits = peakNits
            $0.awaitsSourcePeak = !hasStaticPeak
            $0.lastMode = Mode()
            $0.lastDoviMetadata = nil
        }
        renderer?.updateUniforms { $0.sourcePeakNits = peakNits }
    }

    /// Reports the curve of the render mode switched to: the system's, or the Metal one the last frame used, at the
    /// peak and target the shader has (L1's and the user's scale on them).
    func renderModeDidChange(to mode: RenderMode) {
        guard mode == .metalToneMap else {
            monitor.updateToneMapParams(PlayerPerformanceMonitor.ToneMapParams(mode: .appleXDR))
            return
        }
        let (engineMode, peak, target) = frameState.withLock {
            state -> (PlayerPerformanceMonitor.ToneMapEngineMode, Float, Float) in
            let mode: PlayerPerformanceMonitor.ToneMapEngineMode =
                state.lastMode.usesL2Trim
                ? .doviL2Trim : Self.engineMode(of: state.lastMode, peakNits: state.smoothedPeakNits)
            return (mode, state.smoothedPeakNits, state.smoothedTargetNits)
        }
        monitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(mode: engineMode, peakNits: peak, targetNits: target))
    }

    /// Follows the Profile 5 reshaping through frames given to the display layer (`.system`), which composes them
    /// itself and has no curve to resolve: a still of one composes it with the reshaping on screen (`stillReshaping`).
    nonisolated func trackReshaping(doviMetadata: DolbyVisionFrameMetadata?) {
        frameState.withLock { $0.reshaper.update(with: doviMetadata) }
    }

    /// The Profile 5 reshaping a frame with `doviMetadata` is shown with: its RPU's, or for a frame without one the last
    /// RPU's, which it keeps. Nil for other media.
    nonisolated func stillReshaping(doviMetadata: DolbyVisionFrameMetadata?) -> ToneMapUniforms.DolbyVisionReshaping? {
        frameState.withLock { state in
            guard state.reshaper.isProfile5 else { return nil }
            var reshaper = state.reshaper
            reshaper.update(with: doviMetadata)
            return reshaper.uniforms
        }
    }

    /// Resolves the curve for one frame's Dolby Vision metadata (L1 and L2 trims; the held or static values without
    /// RPU), writes it to the renderer's uniforms and reports it. Returns how the frame was tone-mapped. Called by the
    /// display link and by direct renders (seek preview, frame steps), so paused frame-stepping over Dolby Vision
    /// content keeps the curve of playback. `restartsSmoothing` takes the frame's L1 as is, as on a scene refresh: for a
    /// frame drawn again with no playback before it to smooth from (after a render mode switch or a seek).
    nonisolated func applyFrame(doviMetadata: DolbyVisionFrameMetadata?, restartsSmoothing: Bool = false) -> Mode {
        struct ResolvedParams {
            var trim: DolbyVisionFrameMetadata.Level2Trim?
            let peakNits: Float
            let targetNits: Float
            let mode: Mode
            /// The Profile 5 reshaping to apply; nil for other media.
            let reshaping: ToneMapUniforms.DolbyVisionReshaping?
        }

        let resolved = frameState.withLock { state -> ResolvedParams in
            state.lastDoviMetadata = doviMetadata
            state.reshaper.update(with: doviMetadata)
            let reshaping = state.reshaper.isProfile5 ? state.reshaper.uniforms : nil

            // Without a static peak in the container, the first RPU's source display peak (the mastering display's,
            // so static too) stands in for it, once, before any L1: L1 then moves from it. Only this state takes it: the
            // main actor's `baseTargetNits` (which the UI shows, and a `targetNitsScale` change restores until the next
            // L1) keeps the default peak's. The two differ only for a source peak below 1000 nits without L1.
            if state.awaitsSourcePeak, let sourceMaxPQ = doviMetadata?.sourceMaxPQ, sourceMaxPQ > 0 {
                let sourcePeakNits = max(DolbyVisionRPUParser.pqToNits(Float(sourceMaxPQ) / 4095.0), 100.0)
                let rawTarget = Self.adaptiveTargetNits(maxPeakNits: sourcePeakNits)
                state.basePeakNits = sourcePeakNits
                state.smoothedPeakNits = sourcePeakNits
                state.smoothedTargetNits = Self.scaledTargetNits(rawTarget, scale: state.targetNitsScale)
            }
            // Without L1 (no RPU, e.g. HDR10 or a frame whose RPU failed to parse) the smoothed values hold: they
            // start as the stream's static ones on load and only L1 moves them, so a lone frame without RPU in a
            // Dolby Vision scene keeps its brightness instead of flashing to the static mastering peak.
            if let l1 = doviMetadata?.l1 {
                let alpha: Float = restartsSmoothing || doviMetadata?.sceneRefresh == true ? 1.0 : 0.15
                let dynamicPeak = l1.maxNits > 0 ? l1.maxNits : state.basePeakNits
                let rawTarget = Self.adaptiveTargetNits(maxPeakNits: dynamicPeak, maxFallNits: l1.avgNits)
                let scaledTarget = Self.scaledTargetNits(rawTarget, scale: state.targetNitsScale)

                state.smoothedPeakNits = (alpha * dynamicPeak) + ((1.0 - alpha) * state.smoothedPeakNits)
                state.smoothedTargetNits = (alpha * scaledTarget) + ((1.0 - alpha) * state.smoothedTargetNits)
            }
            if doviMetadata?.l1 != nil || doviMetadata?.sourceMaxPQ ?? 0 > 0 {
                state.awaitsSourcePeak = false
            }
            guard let dovi = doviMetadata else {
                return ResolvedParams(
                    peakNits: state.smoothedPeakNits,
                    targetNits: state.smoothedTargetNits,
                    mode: state.lastMode,
                    reshaping: reshaping
                )
            }

            // L1 drives the BT.2390 base curve; an authored 100-nit L2 trim is applied on top of its output (in the
            // shader), as Dolby applies trims to its display-management curve, if the user turned them on (an
            // approximation; off by default). A neutral trim changes nothing.
            let trim = state.appliesTrims ? dovi.sdrTrim.flatMap { $0.isNeutral ? nil : $0 } : nil
            state.lastMode = Mode(
                usesL1: dovi.l1 != nil, usesL2Trim: trim != nil, usesReshaping: reshaping?.isActive == 1)
            return ResolvedParams(
                trim: trim,
                peakNits: state.smoothedPeakNits,
                targetNits: state.smoothedTargetNits,
                mode: state.lastMode,
                reshaping: reshaping
            )
        }

        let trim = resolved.trim
        let reshaping = resolved.reshaping
        renderer?.updateUniforms { uniforms in
            uniforms.hasDoviL2Trim = trim != nil ? 1 : 0
            if let trim {
                uniforms.doviTrimSlope = trim.slope
                uniforms.doviTrimOffset = trim.offset
                uniforms.doviTrimPower = trim.power
                uniforms.doviTrimSaturation = trim.saturationGain
                uniforms.doviTrimTargetNits = trim.targetNits
            }
            uniforms.sourcePeakNits = resolved.peakNits
            uniforms.targetNits = resolved.targetNits
            if let reshaping { uniforms.doviReshaping = reshaping }
        }
        monitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(
                mode: trim != nil ? .doviL2Trim : Self.engineMode(of: resolved.mode, peakNits: resolved.peakNits),
                slope: trim?.slope ?? 1.0,
                offset: trim?.offset ?? 0.0,
                power: trim?.power ?? 1.0,
                saturation: trim?.saturationGain ?? 0.0,
                peakNits: resolved.peakNits,
                targetNits: resolved.targetNits
            )
        )
        return resolved.mode
    }

    /// Computes the optimal target reference white (nits) for ITU-R BT.2390 tone mapping
    /// on standard SDR displays, adapting to content peak and frame-average luminance.
    public nonisolated static func adaptiveTargetNits(
        baseTargetNits: Float = referenceWhiteNits,
        maxPeakNits: Float,
        maxFallNits: Float = 0.0
    ) -> Float {
        // If content is high-peak mastering (>= 950 nits) and not extremely dark, keep ITU reference (203.0)
        if maxPeakNits >= 950.0 && (maxFallNits == 0 || maxFallNits >= 120.0) {
            return baseTargetNits
        }

        // Scale reference white down smoothly for lower-peak mastering (300...1000 -> 100...baseTargetNits)
        var target = 100.0 + (baseTargetNits - 100.0) * max(min((maxPeakNits - 300.0) / 700.0, 1.0), 0.0)

        // If the scene average (MaxFALL) is known and low (< 100 nits, e.g. low-key dark drama),
        // adjust the target white to prevent crushing midtones and shadows
        if maxFallNits > 0 && maxFallNits < 100.0 {
            let fallFactor = max(maxFallNits / 100.0, 0.7)
            target = min(target, 100.0 + (target - 100.0) * fallFactor)
        }

        return max(min(target, baseTargetNits), 100.0)
    }

    /// An adapted reference white scaled by the user's multiplier, within what an SDR display can take.
    nonisolated static func scaledTargetNits(_ nits: Float, scale: Float) -> Float {
        max(min(nits * scale, 500.0), 80.0)
    }

    /// The monitor's curve for a frame tone-mapped as `mode` without an L2 trim.
    private nonisolated static func engineMode(of mode: Mode, peakNits: Float)
        -> PlayerPerformanceMonitor.ToneMapEngineMode
    {
        if mode.usesL1 { return .doviL1Auto }
        return peakNits > 105.0 ? .bt2390 : .directSDR
    }

    /// Recomputes `targetNits` from the base and the scale, and restarts the smoothed curve from it.
    private func updateTargetNits() {
        let base = baseTargetNits
        let effective = Self.scaledTargetNits(base, scale: targetNitsScale)
        targetNits = effective
        frameState.withLock {
            $0.smoothedTargetNits = effective
        }
        renderer?.updateUniforms { $0.targetNits = effective }
        monitor.updateTargetNits(effective)
    }

    /// Uniforms are written in one locked step (`updateUniforms`), never through `uniforms`' getter and setter: the
    /// display link updates them meanwhile (`applyFrame`), and a copy read before would put back its stale curve.
    private func updateShadowLiftUniform() {
        let lift = appliedShadowLift
        renderer?.updateUniforms { $0.outputShadowLift = lift }
    }
}
