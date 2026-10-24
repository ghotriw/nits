import CoreVideo
import Foundation
import Metal
import Testing

@testable import NitsCore

/// Renders flat grey PQ frames through the tone-mapping shader and compares the output, so the L2 trim is checked
/// as applied: on top of BT.2390, not instead of it.
@Suite("Dolby Vision L2 Trim Shader", .hostDependent)
struct DolbyVisionTrimShaderTests {
    /// Full-range 16-bit luma code of a grey at `nits` (PQ).
    private static func pqCode(nits: Float) -> UInt16 {
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        let powered = pow(nits / 10000.0, m1)
        let pq = pow((c1 + c2 * powered) / (1.0 + c3 * powered), m2)
        return UInt16((pq * 65535.0).rounded())
    }

    private static func baseUniforms() -> ToneMapUniforms {
        var uniforms = ToneMapUniforms(targetNits: 203.0, sourcePeakNits: 4000.0, outputSharpness: 0.0)
        uniforms.isFullRange = 1
        return uniforms
    }

    /// The 10-bit green output of a flat grey frame at `nits`.
    private static func render(nits: Float, uniforms: ToneMapUniforms) throws -> UInt32? {
        try renderPixel(nits: nits, chroma: [32768, 32768], uniforms: uniforms).map { ($0 >> 10) & 0x3FF }
    }

    /// The packed `.bgr10a2Unorm` output of a flat frame with luma at `nits` and the given full-range Cb / Cr codes.
    private static func renderPixel(nits: Float, chroma: [UInt16], uniforms: ToneMapUniforms) throws -> UInt32? {
        try renderRawTexels(luma: pqCode(nits: nits), chroma: chroma, uniforms: uniforms)
    }

    private static func withTrim(slope: Float = 1.0, offset: Float = 0.0, power: Float = 1.0) -> ToneMapUniforms {
        var uniforms = baseUniforms()
        uniforms.hasDoviL2Trim = 1
        uniforms.doviTrimSlope = slope
        uniforms.doviTrimOffset = offset
        uniforms.doviTrimPower = power
        uniforms.doviTrimSaturation = 0.0
        uniforms.doviTrimTargetNits = 100.0
        return uniforms
    }

    @Test("A neutral trim leaves the BT.2390 output unchanged, highlights included")
    func neutralTrimKeepsBaseCurve() throws {
        for nits: Float in [10, 100, 1000] {
            guard let base = try Self.render(nits: nits, uniforms: Self.baseUniforms()),
                let trimmed = try Self.render(nits: nits, uniforms: Self.withTrim())
            else { return }
            #expect(abs(Int(base) - Int(trimmed)) <= 1, "at \(nits) nits: base \(base), trimmed \(trimmed)")
        }
    }

    @Test("A neutral trim does not clip a highlight below the source peak to white")
    func neutralTrimKeepsHighlightDetail() throws {
        guard let highlight = try Self.render(nits: 1000, uniforms: Self.withTrim()),
            let peak = try Self.render(nits: 4000, uniforms: Self.withTrim())
        else { return }
        #expect(highlight < peak)
    }

    @Test("Slope and offset trims move the base curve in their direction")
    func trimsAdjustBaseCurve() throws {
        guard let neutral = try Self.render(nits: 100, uniforms: Self.withTrim()),
            let lowerSlope = try Self.render(nits: 100, uniforms: Self.withTrim(slope: 0.8)),
            let raisedOffset = try Self.render(nits: 100, uniforms: Self.withTrim(offset: 0.05))
        else { return }
        #expect(lowerSlope < neutral)
        #expect(raisedOffset > neutral)
    }

    @Test("A power trim keeps the hue of a colour")
    func powerTrimKeepsHue() throws {
        // An in-gamut orange: Cb below, Cr above neutral.
        let chroma: [UInt16] = [30000, 36000]
        guard let base = try Self.renderPixel(nits: 20, chroma: chroma, uniforms: Self.withTrim()),
            let trimmed = try Self.renderPixel(nits: 20, chroma: chroma, uniforms: Self.withTrim(power: 1.3))
        else { return }
        func channels(_ pixel: UInt32) -> [Float] {
            [0, 10, 20].map { Float((pixel >> $0) & 0x3FF) / 1023.0 }
        }
        // Scaling linear RGB keeps the ratios of the gamma-encoded channels (up to the sRGB toe); per-channel curves
        // change them.
        let (b, t) = (channels(base), channels(trimmed))
        #expect(t[2] < b[2], "the trim should darken: base \(b), trimmed \(t)")
        let baseRatio = b[1] / max(b[2], 1e-3)
        let trimmedRatio = t[1] / max(t[2], 1e-3)
        #expect(abs(baseRatio - trimmedRatio) < 0.02, "ratio base \(baseRatio), trimmed \(trimmedRatio)")
    }

    @Test("Dolby Vision Profile 5 takes the IPT-PQ-c2 HDR path even when VUI color tags defaulted to Rec.709")
    func profile5IgnoresRec709FallbackTags() throws {
        // Unspecified VUI reads as BT.709 primaries and transfer function.
        let (primaries, transferFunction) = ToneMapController.shaderColor(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2, isDolbyVisionProfile5: true)
        #expect(primaries == .bt2020 && transferFunction == .pq)

        var profile5 = Self.baseUniforms()
        profile5.colorSpaceMode = 2
        profile5.colorPrimaries = primaries.shaderIndex
        profile5.transferFunction = transferFunction.shaderIndex

        guard let outProfile5 = try Self.renderPixel(nits: 100, chroma: [32768, 32768], uniforms: profile5),
            let outPQ2020 = try Self.renderPixel(nits: 100, chroma: [32768, 32768], uniforms: Self.baseUniforms())
        else { return }

        let gProfile5 = Int((outProfile5 >> 10) & 0x3FF)
        let gPQ2020 = Int((outPQ2020 >> 10) & 0x3FF)
        #expect(abs(gProfile5 - gPQ2020) <= 2, "Profile 5 neutral grey \(gProfile5) should match PQ grey \(gPQ2020)")
    }

    @Test("Dolby Vision Profile 5 RPU polynomial reshaping expands 10-bit P010 video-range IPT-PQ-c2 correctly")
    func profile5RPUReshapingMatchesStandardIPT() throws {
        // 10-bit P010 neutral grey at 100 nits in video range [64..940], shifted left by 6 for .r16Unorm / .rg16Unorm.
        let pq100 = Float(Self.pqCode(nits: 100)) / 65535.0
        let code10BitVideoRange = UInt16((64.0 + pq100 * 876.0).rounded())
        let p010Luma = code10BitVideoRange << 6
        let p010Chroma: [UInt16] = [512 << 6, 512 << 6]

        // Reshaping curve from Apple's dvh1.05 stream: [-612867, 9803467, 0] / 2^23 for I, [-599187, 9584640, 0] / 2^23 for P/T.
        let denom: Float = Float(1 << 23)
        let iCurve = DolbyVisionFrameMetadata.ReshapingCurve(
            pivots: [0.0, 1.0],
            polyCoeffs: [SIMD3<Float>(-612867.0 / denom, 9803467.0 / denom, 0.0)]
        )
        let ptCurve = DolbyVisionFrameMetadata.ReshapingCurve(
            pivots: [0.0, 1.0],
            polyCoeffs: [SIMD3<Float>(-599187.0 / denom, 9584640.0 / denom, 0.0)]
        )

        var reshapedUniforms = Self.baseUniforms()
        reshapedUniforms.colorSpaceMode = 2
        reshapedUniforms.isFullRange = 0
        reshapedUniforms.doviReshaping.setCurves([iCurve, ptCurve, ptCurve])

        var unreshapedVideoRange = Self.baseUniforms()
        unreshapedVideoRange.colorSpaceMode = 2
        unreshapedVideoRange.isFullRange = 0

        guard
            let reshapedPixel = try Self.renderRawTexels(
                luma: p010Luma, chroma: p010Chroma, uniforms: reshapedUniforms),
            let directPixel = try Self.renderRawTexels(
                luma: p010Luma, chroma: p010Chroma, uniforms: unreshapedVideoRange)
        else { return }

        let rReshaped = Int((reshapedPixel >> 20) & 0x3FF)
        let gReshaped = Int((reshapedPixel >> 10) & 0x3FF)
        let bReshaped = Int(reshapedPixel & 0x3FF)
        let gDirect = Int((directPixel >> 10) & 0x3FF)

        #expect(
            abs(rReshaped - gReshaped) <= 2,
            "reshaped neutral grey should stay achromatic: R=\(rReshaped) G=\(gReshaped) B=\(bReshaped)")
        #expect(abs(bReshaped - gReshaped) <= 2)
        #expect(abs(gReshaped - gDirect) <= 3, "reshaped luma \(gReshaped) should match video-range luma \(gDirect)")
    }

    @Test("ToneMapUniforms memory layout matches Metal shader struct")
    func toneMapUniformsMemoryLayoutMatchesMetal() {
        let reshaping = MemoryLayout<ToneMapUniforms.DolbyVisionReshaping>.self
        #expect(MemoryLayout<ToneMapUniforms>.offset(of: \.doviReshaping) == 80)
        #expect(reshaping.offset(of: \.iptToLms) == 16)
        #expect(reshaping.offset(of: \.pieceCounts) == 128)
        #expect(reshaping.offset(of: \.pivots) == 192)
        #expect(reshaping.offset(of: \.mmrCoeffs) == 672)
        #expect(reshaping.stride == 864)
        #expect(MemoryLayout<ToneMapUniforms>.stride == 944)
    }

    @Test("Dolby Vision Profile 5 RPU MMR reshaping evaluates higher-order chroma regression")
    func profile5RPUReshapingMMRSelection() throws {
        var uniforms = Self.baseUniforms()
        uniforms.colorSpaceMode = 2
        uniforms.bitDepth = 8
        uniforms.isFullRange = 1
        // I: polynomial identity; P and T: order-1 MMR with zero coefficients, so both equal the constant 0.5, which
        // the default offset brings to 0: a neutral grey.
        let identity = DolbyVisionFrameMetadata.ReshapingCurve(pivots: [0, 1], polyCoeffs: [SIMD3(0, 1, 0)])
        let mmr = DolbyVisionFrameMetadata.ReshapingCurve(
            pivots: [0, 1],
            mmr: DolbyVisionFrameMetadata.MMRPiece(order: 1, constant: 0.5, coefs: Array(repeating: 0, count: 7)))
        uniforms.doviReshaping.setCurves([identity, mmr, mmr])
        #expect(uniforms.doviReshaping.pivotMax == SIMD3(repeating: 1), "an MMR component ends at its last pivot")

        // Chroma far off neutral: only the MMR constant can bring it back.
        guard let pixel = try Self.renderRawTexels(luma: 32768, chroma: [8192, 57344], uniforms: uniforms)
        else { return }
        let (r, g, b) = (Int((pixel >> 20) & 0x3FF), Int((pixel >> 10) & 0x3FF), Int(pixel & 0x3FF))
        #expect(abs(r - g) <= 2 && abs(b - g) <= 2, "MMR chroma should be neutral: R=\(r) G=\(g) B=\(b)")
    }

    @Test("Dolby Vision Profile 5 RPU multi-piece reshaping correctly selects piecewise polynomials")
    func profile5RPUReshapingMultiPieceSelection() throws {
        // Test two pieces for component 0 (I) with pivot at 0.5:
        // Piece 0 in [0.0, 0.5]: linear identity y = x -> c = (0.0, 1.0, 0.0)
        // Piece 1 in [0.5, 1.0]: steep slope y = -0.5 + 2.0 * x -> c = (-0.5, 2.0, 0.0)
        var uniforms = Self.baseUniforms()
        uniforms.colorSpaceMode = 2
        uniforms.bitDepth = 8
        uniforms.isFullRange = 1
        let identity = DolbyVisionFrameMetadata.ReshapingCurve(pivots: [0, 1], polyCoeffs: [SIMD3(0, 1, 0)])
        let twoPieces = DolbyVisionFrameMetadata.ReshapingCurve(
            pivots: [0, 0.5, 1], polyCoeffs: [SIMD3(0, 1, 0), SIMD3(-0.5, 2, 0)])
        uniforms.doviReshaping.setCurves([twoPieces, identity, identity])

        // For bitDepth = 8, luma values in .r16Unorm map directly from [0, 65535] to [0.0, 1.0].
        // At x = 0.25 (16384): falls into Piece 0 -> output = 0.25
        // At x = 0.75 (49152): falls into Piece 1 -> output = 2*(0.75) - 0.5 = 1.0
        let chroma: [UInt16] = [32768, 32768]
        guard
            let piece0Pixel = try Self.renderRawTexels(luma: 16384, chroma: chroma, uniforms: uniforms),
            let piece1Pixel = try Self.renderRawTexels(luma: 49152, chroma: chroma, uniforms: uniforms)
        else { return }

        let gPiece0 = Int((piece0Pixel >> 10) & 0x3FF)
        let gPiece1 = Int((piece1Pixel >> 10) & 0x3FF)
        #expect(
            gPiece1 > gPiece0 + 100,
            "piece 1 output (\(gPiece1)) should be significantly brighter than piece 0 (\(gPiece0))")

        // Also compare with an identity single-piece curve at x = 0.75 (where piece 0 would yield 0.75 instead of 1.0)
        var identityUniforms = uniforms
        identityUniforms.doviReshaping.setCurves([identity, identity, identity])
        guard let identityPixel = try Self.renderRawTexels(luma: 49152, chroma: chroma, uniforms: identityUniforms)
        else { return }
        let gIdentity = Int((identityPixel >> 10) & 0x3FF)
        #expect(
            gPiece1 > gIdentity + 10,
            "piece 1 steep curve (\(gPiece1)) should exceed identity curve (\(gIdentity)) at x=0.75")
    }

    private static func renderRawTexels(luma: UInt16, chroma: [UInt16], uniforms: ToneMapUniforms) throws -> UInt32? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let library = try device.makeDefaultLibrary(bundle: .module)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "hdrVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "hdrToneMapFragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let size = 4
        func texture(_ format: MTLPixelFormat, _ texel: [UInt16]) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size, height: size, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let pixels = [UInt16]((0..<(size * size)).flatMap { _ in texel })
            pixels.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: size * texel.count * 2)
            }
            return texture
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgr10a2Unorm, width: size, height: size, mipmapped: false)
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        guard let lumaTexture = texture(.r16Unorm, [luma]),
            let chromaTexture = texture(.rg16Unorm, chroma),
            let output = device.makeTexture(descriptor: outputDescriptor),
            let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        var sourceRect = SIMD4<Float>(0, 0, 1, 1)
        encoder.setVertexBytes(&sourceRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        var bytes = uniforms
        encoder.setFragmentBytes(&bytes, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixel: UInt32 = 0
        output.getBytes(&pixel, bytesPerRow: size * 4, from: MTLRegionMake2D(1, 1, 1, 1), mipmapLevel: 0)
        return pixel
    }
}

/// How Dolby Vision RPU metadata resolves into the renderer's tone-mapping uniforms.
@Suite("Dolby Vision Tone Map Resolution", .hostDependent)
@MainActor
struct DolbyVisionToneMapResolutionTests {
    private static let l1Frame = DolbyVisionFrameMetadata(
        sceneRefresh: true, l1: DolbyVisionFrameMetadata.Level1(minPQ: 0, maxPQ: 2400, avgPQ: 1000), l2Trims: [])

    private static func trim(slope: UInt16) -> DolbyVisionFrameMetadata.Level2Trim {
        DolbyVisionFrameMetadata.Level2Trim(
            targetMaxPQ: 2081, trimSlope: slope, trimOffset: 2048, trimPower: 2048, trimChromaWeight: 2048,
            trimSaturationGain: 2048)
    }

    @Test("L2 trims are off by default: a real trim is not applied")
    func trimsOffByDefault() {
        let engine = PlayerEngine.makeForTesting()
        guard let renderer = engine.metalRenderer else { return }
        #expect(engine.toneMapping.applyDolbyVisionTrims == false)

        let mode = engine.toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(
                sceneRefresh: true, l1: Self.l1Frame.l1, l2Trims: [Self.trim(slope: 1800)]))
        #expect(mode == ToneMapController.Mode(usesL1: true))
        #expect(renderer.uniforms.hasDoviL2Trim == 0)
    }

    @Test("Turning trims on and off while paused re-resolves the last frame")
    func toggleReResolvesLastFrame() {
        let engine = PlayerEngine.makeForTesting()
        guard let renderer = engine.metalRenderer else { return }
        engine.renderMode = .metalToneMap
        #expect(engine.activeRenderMode == .metalToneMap)

        _ = engine.toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(
                sceneRefresh: true, l1: Self.l1Frame.l1, l2Trims: [Self.trim(slope: 1800)]))
        #expect(renderer.uniforms.hasDoviL2Trim == 0)
        engine.toneMapping.applyDolbyVisionTrims = true
        #expect(renderer.uniforms.hasDoviL2Trim == 1)
        engine.toneMapping.applyDolbyVisionTrims = false
        #expect(renderer.uniforms.hasDoviL2Trim == 0)
    }

    @Test("With trims on, a neutral L2 trim is not applied; a real one is")
    func neutralTrimIsSkipped() {
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(applyDolbyVisionTrims: true))
        guard let renderer = engine.metalRenderer else { return }
        let l1 = Self.l1Frame.l1

        let neutralMode = engine.toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(sceneRefresh: true, l1: l1, l2Trims: [Self.trim(slope: 2048)]))
        #expect(neutralMode == ToneMapController.Mode(usesL1: true))
        #expect(renderer.uniforms.hasDoviL2Trim == 0)

        let trimmedMode = engine.toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(sceneRefresh: true, l1: l1, l2Trims: [Self.trim(slope: 1800)]))
        #expect(trimmedMode == ToneMapController.Mode(usesL1: true, usesL2Trim: true))
        #expect(renderer.uniforms.hasDoviL2Trim == 1)
    }

    @Test("A frame without RPU keeps the scene's L1 peak instead of the static one")
    func frameWithoutRPUHoldsL1Values() {
        let engine = PlayerEngine.makeForTesting()
        guard let renderer = engine.metalRenderer else { return }

        _ = engine.toneMapping.applyFrame(doviMetadata: Self.l1Frame)
        let scenePeak = renderer.uniforms.sourcePeakNits
        let sceneTarget = renderer.uniforms.targetNits
        let staticPeak = engine.toneMapping.frameState.withLock { $0.basePeakNits }
        #expect(abs(scenePeak - staticPeak) > 50, "the L1 scene peak should differ from the static one")

        _ = engine.toneMapping.applyFrame(doviMetadata: nil)
        #expect(renderer.uniforms.sourcePeakNits == scenePeak)
        #expect(renderer.uniforms.targetNits == sceneTarget)
    }

    @Test("The reference white follows the scene's L1 peak between 100 nits and the static white, not its average")
    func referenceWhiteFollowsScenePeak() {
        let engine = PlayerEngine.makeForTesting()
        guard let renderer = engine.metalRenderer else { return }

        // About 600 nits peak and 12 nits average: highlights an SDR display needs room for under the static white.
        let dimScene = DolbyVisionFrameMetadata(
            sceneRefresh: true, l1: DolbyVisionFrameMetadata.Level1(minPQ: 0, maxPQ: 2867, avgPQ: 1270), l2Trims: [])
        _ = engine.toneMapping.applyFrame(doviMetadata: dimScene)
        #expect(renderer.uniforms.sourcePeakNits < 700)
        #expect(renderer.uniforms.targetNits == ToneMapController.referenceWhiteNits)

        // A night scene peaking at 100 nits fits under SDR white: white 100, as the XDR presentation shows it.
        let nightScene = DolbyVisionFrameMetadata(
            sceneRefresh: true, l1: DolbyVisionFrameMetadata.Level1(minPQ: 0, maxPQ: 2081, avgPQ: 800), l2Trims: [])
        _ = engine.toneMapping.applyFrame(doviMetadata: nightScene)
        #expect(abs(renderer.uniforms.targetNits - 100) < 1)

        // The user's multiplier scales the scene's white, as on a paused frame: it doesn't restore the static one.
        engine.toneMapping.targetNitsScale = 1.5
        #expect(abs(renderer.uniforms.targetNits - 150) < 1.5)
    }

    @Test("Redrawing the current frame (paused, after a render mode switch) tone-maps it with its own RPU, unsmoothed")
    func redrawUsesFrameRPU() throws {
        let engine = PlayerEngine.makeForTesting()
        guard engine.metalRenderer != nil else { return }
        engine.renderMode = .metalToneMap
        guard engine.activeRenderMode == .metalToneMap else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &pixelBuffer)
        let buffer = try #require(pixelBuffer)
        // Mid-scene, so the display link would only smooth towards its L1.
        let frame = DolbyVisionFrameMetadata(sceneRefresh: false, l1: Self.l1Frame.l1, l2Trims: [])
        let l1Peak = try #require(frame.l1).maxNits
        engine.frameQueue.setLastRendered(buffer: buffer, pts: 1.0, hdrMetadata: FrameHDRMetadata(dolbyVision: frame))
        #expect(engine.toneMapping.frameState.withLock { $0.lastHDRMetadata?.dolbyVision } == nil)

        engine.renderCurrentFrame(at: .invalid)
        let (lastMetadata, peak) = engine.toneMapping.frameState.withLock {
            ($0.lastHDRMetadata?.dolbyVision, $0.smoothedPeakNits)
        }
        #expect(lastMetadata == frame)
        #expect(abs(peak - l1Peak) < 0.01, "the redrawn frame's peak \(peak) should be its L1 peak \(l1Peak)")
    }

    @Test("Each Profile 5 RPU sets the reshaping whole; a frame without RPU keeps it")
    func eachRPUSetsReshapingWhole() {
        let engine = PlayerEngine.makeForTesting()
        guard let renderer = engine.metalRenderer else { return }
        engine.toneMapping.frameState.withLock { $0.reshaper.reset(isProfile5: true) }

        let dummyCurve = DolbyVisionFrameMetadata.ReshapingCurve(
            pivots: [0.0, 1.0],
            polyCoeffs: [SIMD3<Float>(0.0, 1.0, 0.0)]
        )
        let polyMetadata = DolbyVisionFrameMetadata(
            sceneRefresh: true,
            l1: Self.l1Frame.l1,
            l2Trims: [],
            reshapingCurvesState: .curves([dummyCurve, dummyCurve, dummyCurve])
        )

        // 1. Send frame with polynomial curves
        let polyMode = engine.toneMapping.applyFrame(doviMetadata: polyMetadata)
        #expect(renderer.uniforms.doviReshaping.isActive == 1)
        #expect(polyMode.name == "Metal SDR (DoVi Reshaping + L1)")

        // 2. Send frame with reusePrevious, which Profile 5 forbids: no reshaping by another frame's curves
        let reuseMetadata = DolbyVisionFrameMetadata(
            sceneRefresh: false,
            l1: Self.l1Frame.l1,
            l2Trims: [],
            reshapingCurvesState: .reusePrevious
        )
        let reuseMode = engine.toneMapping.applyFrame(doviMetadata: reuseMetadata)
        #expect(renderer.uniforms.doviReshaping.isActive == 0)
        #expect(reuseMode == ToneMapController.Mode(usesL1: true))

        // 3. Curves again, kept by a frame without RPU, then a frame with unsupported reshaping: no reshaping
        let unsupportedMetadata = DolbyVisionFrameMetadata(
            sceneRefresh: false,
            l1: Self.l1Frame.l1,
            l2Trims: [],
            reshapingCurvesState: .unsupported
        )
        _ = engine.toneMapping.applyFrame(doviMetadata: polyMetadata)
        #expect(renderer.uniforms.doviReshaping.isActive == 1)
        _ = engine.toneMapping.applyFrame(doviMetadata: nil)
        #expect(renderer.uniforms.doviReshaping.isActive == 1)
        let unsupportedMode = engine.toneMapping.applyFrame(doviMetadata: unsupportedMetadata)
        #expect(renderer.uniforms.doviReshaping.isActive == 0)
        #expect(unsupportedMode == ToneMapController.Mode(usesL1: true))
    }

    @Test("Frame with sourceMaxPQ does not override known static mastering peak of 1000 nits")
    func sourceMaxPQDoesNotOverrideKnown1000NitStaticPeak() {
        let toneMapping = ToneMapController(renderer: nil)
        // Media with known static peak of 1000 nits
        toneMapping.adapt(toPeakNits: 1000.0, fallNits: 150.0, hasStaticPeak: true)

        let metadata = DolbyVisionFrameMetadata(
            sceneRefresh: false,
            l1: nil,
            l2Trims: [],
            sourceMinPQ: 10,
            sourceMaxPQ: 3600  // ~4000 nits
        )
        _ = toneMapping.applyFrame(doviMetadata: metadata)
        let peak = toneMapping.frameState.withLock { $0.basePeakNits }
        #expect(peak == 1000.0)
    }

    @Test("Without a static peak, the first RPU's sourceMaxPQ stands in for it once; later ones don't move the curve")
    func sourceMaxPQStandsInOnceWhenUnknown() {
        let toneMapping = ToneMapController(renderer: nil)
        toneMapping.adapt(toPeakNits: 1000.0, fallNits: 0.0, hasStaticPeak: false)

        func frame(sourceMaxPQ: UInt16) -> DolbyVisionFrameMetadata {
            DolbyVisionFrameMetadata(
                sceneRefresh: false, l1: nil, l2Trims: [], sourceMinPQ: 10, sourceMaxPQ: sourceMaxPQ)
        }
        _ = toneMapping.applyFrame(doviMetadata: frame(sourceMaxPQ: 3600))  // ~4000 nits
        let (smoothedPeak, basePeak) = toneMapping.frameState.withLock { ($0.smoothedPeakNits, $0.basePeakNits) }
        #expect(smoothedPeak > 3000.0)
        #expect(basePeak == smoothedPeak)

        _ = toneMapping.applyFrame(doviMetadata: frame(sourceMaxPQ: 3079))  // ~1000 nits
        #expect(toneMapping.frameState.withLock { $0.smoothedPeakNits } == smoothedPeak)
    }

    @Test("A sourceMaxPQ after L1 doesn't replace the L1 curve")
    func sourceMaxPQAfterL1KeepsCurve() {
        let toneMapping = ToneMapController(renderer: nil)
        toneMapping.adapt(toPeakNits: 1000.0, fallNits: 0.0, hasStaticPeak: false)

        _ = toneMapping.applyFrame(doviMetadata: Self.l1Frame)
        let l1Peak = toneMapping.frameState.withLock { $0.smoothedPeakNits }
        _ = toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(
                sceneRefresh: false, l1: nil, l2Trims: [], sourceMinPQ: 10, sourceMaxPQ: 3600))
        #expect(toneMapping.frameState.withLock { $0.smoothedPeakNits } == l1Peak)
    }
}
