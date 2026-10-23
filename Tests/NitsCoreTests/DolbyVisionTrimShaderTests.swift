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
        guard let lumaTexture = texture(.r16Unorm, [pqCode(nits: nits)]),
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

    private static func withTrim(slope: Float = 1.0, offset: Float = 0.0, power: Float = 1.0) -> ToneMapUniforms {
        var uniforms = baseUniforms()
        uniforms.hasDoViL2Trim = 1
        uniforms.doViTrimSlope = slope
        uniforms.doViTrimOffset = offset
        uniforms.doViTrimPower = power
        uniforms.doViTrimSaturation = 0.0
        uniforms.doViTrimTargetNits = 100.0
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
        #expect(renderer.uniforms.hasDoViL2Trim == 0)
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
        #expect(renderer.uniforms.hasDoViL2Trim == 0)
        engine.toneMapping.applyDolbyVisionTrims = true
        #expect(renderer.uniforms.hasDoViL2Trim == 1)
        engine.toneMapping.applyDolbyVisionTrims = false
        #expect(renderer.uniforms.hasDoViL2Trim == 0)
    }

    @Test("With trims on, a neutral L2 trim is not applied; a real one is")
    func neutralTrimIsSkipped() {
        let engine = PlayerEngine.makeForTesting(configuration: PlayerConfiguration(applyDolbyVisionTrims: true))
        guard let renderer = engine.metalRenderer else { return }
        let l1 = Self.l1Frame.l1

        let neutralMode = engine.toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(sceneRefresh: true, l1: l1, l2Trims: [Self.trim(slope: 2048)]))
        #expect(neutralMode == ToneMapController.Mode(usesL1: true))
        #expect(renderer.uniforms.hasDoViL2Trim == 0)

        let trimmedMode = engine.toneMapping.applyFrame(
            doviMetadata: DolbyVisionFrameMetadata(sceneRefresh: true, l1: l1, l2Trims: [Self.trim(slope: 1800)]))
        #expect(trimmedMode == ToneMapController.Mode(usesL1: true, usesL2Trim: true))
        #expect(renderer.uniforms.hasDoViL2Trim == 1)
    }

    @Test("A frame without RPU keeps the scene's L1 peak and target instead of the static ones")
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
}
