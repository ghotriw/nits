import CoreVideo
import Foundation
import Metal
import NitsKernels
import QuartzCore
import os
import simd

public struct ToneMapUniforms: Sendable {
    public var targetNits: Float = ToneMapController.referenceWhiteNits
    public var sourcePeakNits: Float = 1000.0  // from SEI 144 / mastering display
    public var outputExposure: Float = 1.0
    public var outputSaturation: Float = 1.0
    public var outputWarmCorrection: Float = 0.0
    public var outputHighlightCompression: Float = 0.0
    public var outputShadowDetail: Float = 0.0
    public var outputShadowLift: Float = 0.0
    public var outputSharpness: Float = 0.5  // Default 0.5 for CAS sharpening on 5K display
    public var colorPrimaries: UInt32 = 0  // 0: BT.2020, 1: BT.709, 2: DCI-P3
    public var transferFunction: UInt32 = 0  // 0: PQ, 1: HLG, 2: BT.709 / SDR
    public var bitDepth: UInt32 = 10  // 8 or 10
    public var isFullRange: UInt32 = 0  // 0: Video Range, 1: Full Range
    public var colorSpaceMode: UInt32 = 0  // 0: Standard YCbCr BT.2020, 1: BT.709, 2: Dolby Vision IPT / ICtCp
    public var hasDoviL2Trim: UInt32 = 0  // 0: none, 1: authored L2 SDR trim active
    public var doviTrimSlope: Float = 1.0
    public var doviTrimOffset: Float = 0.0
    public var doviTrimPower: Float = 1.0
    public var doviTrimSaturation: Float = 0.0  // saturation gain, neutral 0
    public var doviTrimTargetNits: Float = 100.0  // peak of the display the L2 trim was authored for

    /// Dolby Vision Profile 5 reshaping and colour matrices; 16-byte aligned, at byte offset 80.
    public var doviReshaping = DolbyVisionReshaping()
    /// Strength of the local contrast (`ContrastRecovery`), 0 ... 1, 0: off: how much of the detail above the low-pass
    /// bypasses the curve. The user's (`ToneMapController.localContrast`); the renderer turns it off for each frame it
    /// can't compute it for.
    public var contrastRecovery: Float = 0

    public init(
        targetNits: Float = ToneMapController.referenceWhiteNits,
        sourcePeakNits: Float = 1000.0,
        outputExposure: Float = 1.0,
        outputSaturation: Float = 1.0,
        outputWarmCorrection: Float = 0.0,
        outputHighlightCompression: Float = 0.0,
        outputShadowDetail: Float = 0.0,
        outputShadowLift: Float = 0.0,
        outputSharpness: Float = 0.5,
        colorPrimaries: UInt32 = 0,
        transferFunction: UInt32 = 0,
        bitDepth: UInt32 = 10,
        isFullRange: UInt32 = 0,
        colorSpaceMode: UInt32 = 0,
        hasDoviL2Trim: UInt32 = 0,
        doviTrimSlope: Float = 1.0,
        doviTrimOffset: Float = 0.0,
        doviTrimPower: Float = 1.0,
        doviTrimSaturation: Float = 0.0,
        doviTrimTargetNits: Float = 100.0
    ) {
        self.targetNits = targetNits
        self.sourcePeakNits = sourcePeakNits
        self.outputExposure = outputExposure
        self.outputSaturation = outputSaturation
        self.outputWarmCorrection = outputWarmCorrection
        self.outputHighlightCompression = outputHighlightCompression
        self.outputShadowDetail = outputShadowDetail
        self.outputShadowLift = outputShadowLift
        self.outputSharpness = outputSharpness
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.bitDepth = bitDepth
        self.isFullRange = isFullRange
        self.colorSpaceMode = colorSpaceMode
        self.hasDoviL2Trim = hasDoviL2Trim
        self.doviTrimSlope = doviTrimSlope
        self.doviTrimOffset = doviTrimOffset
        self.doviTrimPower = doviTrimPower
        self.doviTrimSaturation = doviTrimSaturation
        self.doviTrimTargetNits = doviTrimTargetNits
    }
}

public final class MetalVideoRenderer: @unchecked Sendable {
    public let metalLayer = CAMetalLayer()
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private var pipelineState: (any MTLRenderPipelineState)?
    private var textureCache: CVMetalTextureCache?
    private let renderPassDesc = MTLRenderPassDescriptor()
    private var lastRenderedTextures: (CVMetalTexture?, CVMetalTexture?) = (nil, nil)
    /// Already kept alive by `lastRenderedTextures`; held for `redrawLastFrame()`.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS: Double = -1
    private let renderLock = OSAllocatedUnfairLock()
    private let uniformsLock = OSAllocatedUnfairLock(initialState: ToneMapUniforms())
    private let sourceRectLock = OSAllocatedUnfairLock(initialState: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let lastDrawnLock = OSAllocatedUnfairLock<DrawnFrame?>(initialState: nil)
    /// The pipeline of `doviSignalFragmentShader`, built on the first still that needs it (`signalPipeline()`).
    private let signalPipelineLock = OSAllocatedUnfairLock<(any MTLRenderPipelineState)?>(initialState: nil)
    private var contrastRecovery: ContrastRecovery?
    /// The local contrast's textures for the layer's frames, behind `renderLock`; rebuilt when the frame size changes.
    private var recoveryWorkspace: ContrastRecovery.Workspace?
    /// Bound in place of the local contrast's coefficients when a frame has none (SDR, or no pipeline).
    private var placeholderCoefficients: (any MTLTexture)?

    /// A frame as it was drawn into the layer: what a still of it must repeat (`renderStill`).
    struct DrawnFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        /// Presentation time of the frame, in seconds.
        let pts: Double
        let uniforms: ToneMapUniforms
        let sourceRect: CGRect
        let drawableSize: CGSize
    }

    /// The frame the layer shows, with its time and the uniforms, `sourceRect` and drawable size it was drawn with:
    /// read in one step, so a frame, a curve or a layout drawn after it can't mix into its still. Nil after `clear()`.
    var lastDrawnFrame: DrawnFrame? {
        lastDrawnLock.withLock { $0 }
    }

    /// A copy of the uniforms. Read-only: they change only in one locked step (`updateUniforms`), as the display link
    /// and the main thread both write them; a copy read, changed and set back would undo the other's write.
    public var uniforms: ToneMapUniforms {
        uniformsLock.withLock { $0 }
    }

    /// The part of the frame drawn into the layer, normalized with the origin at the top left (crop, zoom, pan;
    /// see `VideoLayout.sourceRect`). The whole frame by default.
    public var sourceRect: CGRect {
        get { sourceRectLock.withLock { $0 } }
        set { sourceRectLock.withLock { $0 = newValue } }
    }

    public func updateUniforms(_ modify: @Sendable (inout ToneMapUniforms) -> Void) {
        uniformsLock.withLock { modify(&$0) }
    }

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        metalLayer.device = device
        metalLayer.pixelFormat = .bgr10a2Unorm
        metalLayer.framebufferOnly = true
        // Set colorspace to Display P3
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess {
            self.textureCache = cache
        }

        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDesc.colorAttachments[0].storeAction = .store

        setupPipeline()
    }

    private func setupPipeline() {
        guard let defaultLibrary = (try? device.makeDefaultLibrary(bundle: .module)) ?? device.makeDefaultLibrary()
        else {
            AppLog.error(.renderer, "Failed to load Metal default library")
            return
        }

        let vertexFn = defaultLibrary.makeFunction(name: "hdrVertexShader")
        let fragFn = defaultLibrary.makeFunction(name: "hdrToneMapFragmentShader")

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgr10a2Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            AppLog.error(.renderer, "Pipeline state creation failed: \(error)")
        }

        contrastRecovery = ContrastRecovery(device: device, library: defaultLibrary)
        if contrastRecovery == nil {
            AppLog.error(.renderer, "Contrast recovery pipelines failed; tone mapping goes without local contrast")
        }
        let placeholder = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: ContrastRecovery.coefficientFormat, width: 1, height: 1, mipmapped: false)
        placeholder.usage = [.shaderRead]
        placeholderCoefficients = device.makeTexture(descriptor: placeholder)
    }

    /// Encodes the local contrast of an HDR frame into `commandBuffer` at the strength `uniforms` ask for; returns the
    /// texture the fragment shader samples for it (the placeholder, with the strength set to 0, when it is off, for SDR
    /// or without a pipeline). `workspace` is reused when it fits the frame, else replaced.
    private func encodeContrastRecovery(
        into commandBuffer: any MTLCommandBuffer, luma: any MTLTexture, chroma: any MTLTexture,
        uniforms: inout ToneMapUniforms, workspace: inout ContrastRecovery.Workspace?
    ) -> (any MTLTexture)? {
        let strength = min(uniforms.contrastRecovery, 1)
        uniforms.contrastRecovery = 0
        let isSDR = uniforms.transferFunction == 2 || uniforms.colorPrimaries == 1
        guard strength > 0, !isSDR, let contrastRecovery else { return placeholderCoefficients }
        if workspace?.fits(frameWidth: luma.width, frameHeight: luma.height) != true {
            workspace = ContrastRecovery.Workspace(device: device, frameWidth: luma.width, frameHeight: luma.height)
        }
        guard let workspace else { return placeholderCoefficients }
        contrastRecovery.encode(
            into: commandBuffer, luma: luma, chroma: chroma, uniforms: uniforms, workspace: workspace)
        uniforms.contrastRecovery = strength
        return workspace.boxedCoefficients
    }

    /// - Parameters:
    ///   - pts: Presentation time of the frame, in seconds, for a still of it (`lastDrawnFrame`).
    ///   - onGPUCompleted: Called with the command buffer's `gpuEndTime` (host seconds) once the GPU finished the
    ///     frame, 0 if it failed.
    public func render(
        pixelBuffer: CVPixelBuffer, pts: Double,
        onGPUCompleted: (@Sendable (_ gpuEndTime: CFTimeInterval) -> Void)? = nil
    ) {
        renderLock.lock()
        defer { renderLock.unlock() }
        renderLocked(pixelBuffer: pixelBuffer, pts: pts, onGPUCompleted: onGPUCompleted)
    }

    /// Re-renders the last frame at the current `drawableSize`: until the next frame, the layer would otherwise show
    /// the previous drawable scaled to its new size (soft after enlarging the window while paused).
    public func redrawLastFrame() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let lastPixelBuffer else { return }
        renderLocked(pixelBuffer: lastPixelBuffer, pts: lastPTS, onGPUCompleted: nil)
    }

    private func renderLocked(
        pixelBuffer: CVPixelBuffer, pts: Double, onGPUCompleted: (@Sendable (_ gpuEndTime: CFTimeInterval) -> Void)?
    ) {
        guard let pipelineState,
            let textureCache,
            let drawable = metalLayer.nextDrawable()
        else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is8Bit =
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isFull =
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        let yPixelFormat: MTLPixelFormat = is8Bit ? .r8Unorm : .r16Unorm
        let uvPixelFormat: MTLPixelFormat = is8Bit ? .rg8Unorm : .rg16Unorm

        // Plane 0: Y channel
        var yTextureRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            yPixelFormat,
            width,
            height,
            0,
            &yTextureRef
        )

        // Plane 1: UV / CbCr channel (half width & height)
        var uvTextureRef: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            uvPixelFormat,
            width / 2,
            height / 2,
            1,
            &uvTextureRef
        )

        guard yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
            let yTexture = CVMetalTextureGetTexture(yTextureRef!),
            let uvTexture = CVMetalTextureGetTexture(uvTextureRef!)
        else {
            return
        }

        renderPassDesc.colorAttachments[0].texture = drawable.texture

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        var currentUniforms = uniforms
        currentUniforms.bitDepth = is8Bit ? 8 : 10
        currentUniforms.isFullRange = isFull ? 1 : 0
        let recoveryCoefficients = encodeContrastRecovery(
            into: commandBuffer, luma: yTexture, chroma: uvTexture, uniforms: &currentUniforms,
            workspace: &recoveryWorkspace)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }

        encoder.setRenderPipelineState(pipelineState)
        let source = sourceRect
        var sourceRectBytes = SIMD4<Float>(
            Float(source.minX), Float(source.minY), Float(source.width), Float(source.height))
        encoder.setVertexBytes(&sourceRectBytes, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.setFragmentTexture(recoveryCoefficients, index: 2)
        encoder.setFragmentBytes(&currentUniforms, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Retain textures in renderer slot until next frame without allocating a heap closure
        lastRenderedTextures = (yTextureRef, uvTextureRef)
        lastPixelBuffer = pixelBuffer
        lastPTS = pts
        let drawn = DrawnFrame(
            pixelBuffer: pixelBuffer, pts: pts, uniforms: currentUniforms, sourceRect: source,
            drawableSize: CGSize(width: drawable.texture.width, height: drawable.texture.height))
        lastDrawnLock.withLock { $0 = drawn }

        if let onGPUCompleted {
            commandBuffer.addCompletedHandler { onGPUCompleted($0.status == .completed ? $0.gpuEndTime : 0) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// `pixelBuffer` drawn as the layer draws it (same shader) with `uniforms` over `sourceRect` (those of the frame on
    /// screen: `lastDrawnFrame`) into a `width` × `height` texture of the layer's format, as 16-bit Display P3 RGB: the
    /// 10-bit values the layer shows, exactly. Blocks until the GPU is done; the layer's own frames are not held up
    /// meanwhile.
    func renderStill(
        pixelBuffer: CVPixelBuffer, uniforms: ToneMapUniforms, sourceRect: CGRect, width: Int, height: Int
    ) -> CGImage? {
        guard let pipelineState,
            let output = drawStill(
                pixelBuffer, sourceRect: sourceRect, width: width, height: height, pipeline: pipelineState,
                format: .bgr10a2Unorm, uniforms: uniforms)
        else { return nil }
        return Self.displayP3Image(of: output)
    }

    /// A Dolby Vision Profile 5 frame composed by `reshaping` (its RPU's) to its BT.2100 PQ signal, untone-mapped, as
    /// 16-bit RGB in the BT.2100 PQ space, over `sourceRect`. Blocks until the GPU is done.
    func renderDolbyVisionSignal(
        pixelBuffer: CVPixelBuffer, sourceRect: CGRect, width: Int, height: Int,
        reshaping: ToneMapUniforms.DolbyVisionReshaping
    ) -> CGImage? {
        // The shader reads only the reshaping, and the bit depth and range `drawStill` sets from the buffer.
        var signalUniforms = ToneMapUniforms()
        signalUniforms.doviReshaping = reshaping
        guard let signalPipeline = signalPipeline(),
            let output = drawStill(
                pixelBuffer, sourceRect: sourceRect, width: width, height: height, pipeline: signalPipeline,
                format: .rgba16Unorm, uniforms: signalUniforms),
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        else { return nil }
        var rgba = Data(count: width * height * 8)
        rgba.withUnsafeMutableBytes {
            output.getBytes(
                $0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The pipeline of `doviSignalFragmentShader`, built once on first use, as only stills need it.
    private func signalPipeline() -> (any MTLRenderPipelineState)? {
        signalPipelineLock.withLock { pipeline in
            if let pipeline { return pipeline }
            guard let library = (try? device.makeDefaultLibrary(bundle: .module)) ?? device.makeDefaultLibrary()
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "hdrVertexShader")
            descriptor.fragmentFunction = library.makeFunction(name: "doviSignalFragmentShader")
            descriptor.colorAttachments[0].pixelFormat = .rgba16Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            return pipeline
        }
    }

    /// Draws `pixelBuffer` with `pipeline` and `uniforms` (bit depth and range set from the buffer) over `sourceRect`
    /// into a new `width` × `height` texture of `format`, readable from the CPU.
    private func drawStill(
        _ pixelBuffer: CVPixelBuffer, sourceRect source: CGRect, width: Int, height: Int,
        pipeline: any MTLRenderPipelineState, format: MTLPixelFormat, uniforms: ToneMapUniforms
    ) -> (any MTLTexture)? {
        guard width > 0, height > 0, let textureCache else { return nil }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is8Bit =
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isFull =
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let planeWidth = CVPixelBufferGetWidth(pixelBuffer)
        let planeHeight = CVPixelBufferGetHeight(pixelBuffer)

        func planeTexture(_ plane: Int, _ format: MTLPixelFormat, _ width: Int, _ height: Int) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil, format, width, height, plane, &texture)
            return status == kCVReturnSuccess ? texture : nil
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.renderTarget]
        outputDescriptor.storageMode = .shared
        guard
            let yTextureRef = planeTexture(0, is8Bit ? .r8Unorm : .r16Unorm, planeWidth, planeHeight),
            let uvTextureRef = planeTexture(1, is8Bit ? .rg8Unorm : .rg16Unorm, planeWidth / 2, planeHeight / 2),
            let yTexture = CVMetalTextureGetTexture(yTextureRef),
            let uvTexture = CVMetalTextureGetTexture(uvTextureRef),
            let output = device.makeTexture(descriptor: outputDescriptor),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }
        var currentUniforms = uniforms
        currentUniforms.bitDepth = is8Bit ? 8 : 10
        currentUniforms.isFullRange = isFull ? 1 : 0
        // As the layer drew it: with the local contrast if the frame had it, in textures of the still's own.
        var recoveryCoefficients = placeholderCoefficients
        if uniforms.contrastRecovery > 0 {
            var workspace: ContrastRecovery.Workspace?
            recoveryCoefficients = encodeContrastRecovery(
                into: commandBuffer, luma: yTexture, chroma: uvTexture, uniforms: &currentUniforms,
                workspace: &workspace)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        var sourceRectBytes = SIMD4<Float>(
            Float(source.minX), Float(source.minY), Float(source.width), Float(source.height))
        encoder.setVertexBytes(&sourceRectBytes, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.setFragmentTexture(recoveryCoefficients, index: 2)
        encoder.setFragmentBytes(&currentUniforms, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        // The plane textures are only valid while their CVMetalTextures live.
        withExtendedLifetime((yTextureRef, uvTextureRef)) {}
        return output
    }

    /// A `.bgr10a2Unorm` texture (`(A << 30) | (R << 20) | (G << 10) | B`) as 16-bit RGB in Display P3.
    static func displayP3Image(of texture: any MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        var packed = [UInt32](repeating: 0, count: width * height)
        packed.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var rgb = Data(count: width * height * 6)
        packed.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBytes { dst in
                PackedRGBConversion.unpack10BitBGRA(
                    from: src.baseAddress!, to: dst.bindMemory(to: UInt16.self).baseAddress!, count: src.count)
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
            let provider = CGDataProvider(data: rgb as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Clears the Metal layer frame by presenting a black clear frame.
    public func clear() {
        renderLock.lock()
        defer { renderLock.unlock() }

        lastRenderedTextures = (nil, nil)
        lastPixelBuffer = nil
        lastDrawnLock.withLock { $0 = nil }
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderPassDesc.colorAttachments[0].texture = drawable.texture

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
