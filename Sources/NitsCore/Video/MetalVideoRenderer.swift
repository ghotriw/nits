import AppKit
import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

public struct ToneMapUniforms: Sendable {
    public var targetNits: Float = 203.0  // 203 nits standard ITU SDR reference
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
    public var hasDoViL2Trim: UInt32 = 0  // 0: none, 1: authored L2 SDR trim active
    public var doViTrimSlope: Float = 1.0
    public var doViTrimOffset: Float = 0.0
    public var doViTrimPower: Float = 1.0
    public var doViTrimSaturation: Float = 0.0  // saturation gain, neutral 0
    public var doViTrimTargetNits: Float = 100.0  // peak of the display the L2 trim was authored for

    public init(
        targetNits: Float = 203.0,
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
        hasDoViL2Trim: UInt32 = 0,
        doViTrimSlope: Float = 1.0,
        doViTrimOffset: Float = 0.0,
        doViTrimPower: Float = 1.0,
        doViTrimSaturation: Float = 0.0,
        doViTrimTargetNits: Float = 100.0
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
        self.hasDoViL2Trim = hasDoViL2Trim
        self.doViTrimSlope = doViTrimSlope
        self.doViTrimOffset = doViTrimOffset
        self.doViTrimPower = doViTrimPower
        self.doViTrimSaturation = doViTrimSaturation
        self.doViTrimTargetNits = doViTrimTargetNits
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
    private let renderLock = OSAllocatedUnfairLock()
    private let uniformsLock = OSAllocatedUnfairLock(initialState: ToneMapUniforms())

    public var uniforms: ToneMapUniforms {
        get { uniformsLock.withLock { $0 } }
        set { uniformsLock.withLock { $0 = newValue } }
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
    }

    /// - Parameter onGPUCompleted: Called with the command buffer's `gpuEndTime` (host seconds) once the GPU finished
    ///   the frame, 0 if it failed.
    public func render(
        pixelBuffer: CVPixelBuffer, onGPUCompleted: (@Sendable (_ gpuEndTime: CFTimeInterval) -> Void)? = nil
    ) {
        renderLock.lock()
        defer { renderLock.unlock() }
        renderLocked(pixelBuffer: pixelBuffer, onGPUCompleted: onGPUCompleted)
    }

    /// Re-renders the last frame at the current `drawableSize`: until the next frame, the layer would otherwise show
    /// the previous drawable scaled to its new size (soft after enlarging the window while paused).
    public func redrawLastFrame() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let lastPixelBuffer else { return }
        renderLocked(pixelBuffer: lastPixelBuffer, onGPUCompleted: nil)
    }

    private func renderLocked(
        pixelBuffer: CVPixelBuffer, onGPUCompleted: (@Sendable (_ gpuEndTime: CFTimeInterval) -> Void)?
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

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)

        var currentUniforms = uniforms
        currentUniforms.bitDepth = is8Bit ? 8 : 10
        currentUniforms.isFullRange = isFull ? 1 : 0
        encoder.setFragmentBytes(&currentUniforms, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Retain textures in renderer slot until next frame without allocating a heap closure
        lastRenderedTextures = (yTextureRef, uvTextureRef)
        lastPixelBuffer = pixelBuffer

        if let onGPUCompleted {
            commandBuffer.addCompletedHandler { onGPUCompleted($0.status == .completed ? $0.gpuEndTime : 0) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Clears the Metal layer frame by presenting a black clear frame.
    public func clear() {
        renderLock.lock()
        defer { renderLock.unlock() }

        lastRenderedTextures = (nil, nil)
        lastPixelBuffer = nil
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
