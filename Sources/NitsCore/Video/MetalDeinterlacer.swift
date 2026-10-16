import CoreVideo
import Foundation
import Metal
import os

/// Deinterlaces NV12 / P010 frames on the GPU (`deinterlacePlane` in `Deinterlace.metal`): one progressive
/// frame per interlaced frame, at the time of its first field, with no latency and no frame history.
///
/// Decoders call it on frames they know are interlaced (FFmpeg's `AV_FRAME_FLAG_INTERLACED`), before the
/// frame reaches the queue, the seek preview or the step cache, so every consumer sees progressive frames.
final class MetalDeinterlacer: @unchecked Sendable {
    /// A woven sample may stray this far outside its neighbours (about 8 of 255 levels) before it counts as
    /// combing: enough to ignore noise and compression ringing, small enough to catch slow motion.
    static let combThreshold: Float = 0.03

    private struct Params {
        var keptParity: UInt32
        var combThreshold: Float
    }

    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let lock = OSAllocatedUnfairLock()
    private var pool: CVPixelBufferPool?
    private var poolKey: (format: OSType, width: Int, height: Int)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue(),
            let library = (try? device.makeDefaultLibrary(bundle: .module)) ?? device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "deinterlacePlane"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else {
            AppLog.error(.video, "MetalDeinterlacer: Metal pipeline unavailable, interlaced frames stay woven")
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { return nil }
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = cache
    }

    /// A progressive copy of `source`, keeping the temporally first field, or `nil` for unsupported
    /// formats (anything but NV12 / P010) and on GPU failure.
    func deinterlace(_ source: CVPixelBuffer, topFieldFirst: Bool) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        let is8Bit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            is8Bit = true
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            is8Bit = false
        default:
            return nil
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        lock.lock()
        defer { lock.unlock() }

        guard let destination = makeBuffer(format: format, width: width, height: height),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        var params = Params(keptParity: topFieldFirst ? 0 : 1, combThreshold: Self.combThreshold)
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)

        // Plane 0 is luma; plane 1 is CbCr at half resolution, whose rows alternate between fields too.
        let planes: [(index: Int, format: MTLPixelFormat)] = [
            (0, is8Bit ? .r8Unorm : .r16Unorm),
            (1, is8Bit ? .rg8Unorm : .rg16Unorm),
        ]
        var textureRefs: [CVMetalTexture] = []
        for plane in planes {
            guard let input = texture(source, plane: plane.index, format: plane.format),
                let output = texture(destination, plane: plane.index, format: plane.format)
            else {
                encoder.endEncoding()
                return nil
            }
            textureRefs += [input.ref, output.ref]
            encoder.setTexture(input.texture, index: 0)
            encoder.setTexture(output.texture, index: 1)
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: input.texture.width, height: input.texture.height, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(textureRefs) {}
        guard commandBuffer.status == .completed else { return nil }

        CVBufferPropagateAttachments(source, destination)
        CVBufferSetAttachment(destination, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
        CVBufferRemoveAttachment(destination, kCVImageBufferFieldDetailKey)
        return destination
    }

    private func texture(
        _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat
    ) -> (texture: any MTLTexture, ref: CVMetalTexture)? {
        var ref: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &ref)
        guard status == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else { return nil }
        return (texture, ref)
    }

    private func makeBuffer(format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolKey?.format != format || poolKey?.width != width || poolKey?.height != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolKey = (format, width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
