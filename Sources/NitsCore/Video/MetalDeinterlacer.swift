import CoreVideo
import Foundation
import Metal
import os

/// Deinterlaces NV12 / P010 frames on the GPU (`deinterlacePlane` in `Deinterlace.metal`): one progressive
/// frame per kept field, each built from that field and the other one of the same frame. The previous frame, when
/// given, only tells static detail from motion, so there is no latency.
///
/// Decoders call it on frames they know are interlaced (FFmpeg's `AV_FRAME_FLAG_INTERLACED`), before the
/// frame reaches the queue, the seek preview or the step cache, so every consumer sees progressive frames.
final class MetalDeinterlacer: @unchecked Sendable {
    enum Field {
        /// Even rows.
        case top
        /// Odd rows.
        case bottom
    }

    struct Output {
        /// A progressive frame per requested field, in order.
        let frames: [CVPixelBuffer]
        /// Whether the fields show different moments: enough moving samples comb with rows alternating between
        /// the fields (zipping) well beyond what texture produces within a field. `false` for progressive content
        /// stored as interlaced (film in 50i / 60i, PsF, DV shot progressive) and for still interlaced scenes,
        /// where a frame per field would only repeat the picture.
        let fieldsDiffer: Bool
    }

    /// A woven sample may stray this far outside its neighbours (about 8 of 255 levels) before it counts as
    /// combing: enough to ignore noise and compression ringing, small enough to catch slow motion.
    static let combThreshold: Float = 0.03
    /// A sample this close to the previous frame's (about 5 of 255 levels) counts as static.
    static let motionThreshold: Float = 0.02
    /// Fields can differ once more than this share of the tested luma samples zip-comb (about 20 samples of a 576i
    /// frame): a small moving object is enough.
    static let movingSampleShare = 0.0001
    /// ...and only if they zip between the fields this many times more often than within one field, which moving
    /// texture and noise do about as readily (measured: about 2× for DV shot progressive, 9–10× for 50i camera
    /// motion).
    static let combingToTextureRatio = 4.0

    private struct Params {
        var keptParity: UInt32
        var combThreshold: Float
        var hasPrevious: UInt32
        var motionThreshold: Float
        var countsZips: UInt32
    }

    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    /// Zipped luma-sample counters, two per field (between the fields, within a field).
    private let counters: any MTLBuffer
    private static let counterCapacity = 4
    private let lock = OSAllocatedUnfairLock()
    private var pool: CVPixelBufferPool?
    private var poolKey: (format: OSType, width: Int, height: Int)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue(),
            let library = (try? device.makeDefaultLibrary(bundle: .module)) ?? device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "deinterlacePlane"),
            let pipeline = try? device.makeComputePipelineState(function: function),
            let counters = device.makeBuffer(
                length: Self.counterCapacity * MemoryLayout<UInt32>.stride, options: .storageModeShared)
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
        self.counters = counters
    }

    /// A progressive copy of `source` per entry of `fields` (at most two), keeping that field, or `nil` for
    /// unsupported formats (anything but NV12 / P010) and on GPU failure. `previous` is the frame presented just
    /// before `source`; it is ignored unless its format and size match.
    func deinterlace(_ source: CVPixelBuffer, previous: CVPixelBuffer?, keeping fields: [Field]) -> Output? {
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
        let previous = previous.flatMap { previous in
            CVPixelBufferGetPixelFormatType(previous) == format && CVPixelBufferGetWidth(previous) == width
                && CVPixelBufferGetHeight(previous) == height ? previous : nil
        }

        lock.lock()
        defer { lock.unlock() }

        let destinations = fields.compactMap { _ in makeBuffer(format: format, width: width, height: height) }
        guard !fields.isEmpty, fields.count * 2 <= Self.counterCapacity, destinations.count == fields.count,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(pipeline)
        memset(counters.contents(), 0, counters.length)

        // Plane 0 is luma; plane 1 is CbCr at half resolution, whose rows alternate between fields too.
        let planes: [(index: Int, format: MTLPixelFormat)] = [
            (0, is8Bit ? .r8Unorm : .r16Unorm),
            (1, is8Bit ? .rg8Unorm : .rg16Unorm),
        ]
        var textureRefs: [CVMetalTexture] = []
        for plane in planes {
            guard let input = texture(source, plane: plane.index, format: plane.format) else {
                encoder.endEncoding()
                return nil
            }
            textureRefs.append(input.ref)
            encoder.setTexture(input.texture, index: 0)
            // Without a previous frame the shader never reads it; bind the source to keep the slot valid.
            let previousTexture = previous.flatMap { texture($0, plane: plane.index, format: plane.format) }
            if let previousTexture { textureRefs.append(previousTexture.ref) }
            encoder.setTexture(previousTexture?.texture ?? input.texture, index: 2)
            for (fieldIndex, (field, destination)) in zip(fields, destinations).enumerated() {
                guard let output = texture(destination, plane: plane.index, format: plane.format) else {
                    encoder.endEncoding()
                    return nil
                }
                textureRefs.append(output.ref)
                var params = Params(
                    keptParity: field == .top ? 0 : 1, combThreshold: Self.combThreshold,
                    hasPrevious: previousTexture != nil ? 1 : 0, motionThreshold: Self.motionThreshold,
                    countsZips: plane.index == 0 ? 1 : 0)
                encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
                // Chroma passes don't count, but the slot stays bound.
                encoder.setBuffer(counters, offset: fieldIndex * 2 * MemoryLayout<UInt32>.stride, index: 1)
                encoder.setTexture(output.texture, index: 1)
                let threads = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: input.texture.width, height: input.texture.height, depth: 1)
                encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(textureRefs) {}
        guard commandBuffer.status == .completed else { return nil }

        for destination in destinations {
            CVBufferPropagateAttachments(source, destination)
            CVBufferSetAttachment(destination, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
            CVBufferRemoveAttachment(destination, kCVImageBufferFieldDetailKey)
        }

        // Each field's luma pass tests the other field's rows, about half the frame.
        let counts = counters.contents().assumingMemoryBound(to: UInt32.self)
        let betweenFields = fields.indices.map { Double(counts[$0 * 2]) }.max() ?? 0
        let withinField = fields.indices.map { Double(counts[$0 * 2 + 1]) }.max() ?? 0
        let tested = Double(width * height / 2)
        let fieldsDiffer =
            betweenFields > tested * Self.movingSampleShare && betweenFields > withinField * Self.combingToTextureRatio
        return Output(frames: destinations, fieldsDiffer: fieldsDiffer)
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
