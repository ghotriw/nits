import Metal
import MetalPerformanceShaders

/// Local contrast for the Metal tone mapping: the coefficients of a guided filter of the frame's PQ intensity, which
/// `hdrToneMapFragmentShader` reads to put back part of the detail the curve's shoulder compresses
/// (`applyContrastRecovery` in HDRToneMapping.metal tells the method). Computed on the GPU at a quarter of the frame's
/// size before the frame is drawn, in the same command buffer: statistics, a box filter, the coefficients, a box filter.
/// `@unchecked`: it holds only pipeline states, which Metal lets any thread use.
final class ContrastRecovery: @unchecked Sendable {
    /// The guided filter's ε in PQ²: variation well below √ε (~0.06 PQ) is smoothed, edges above it are kept.
    static let epsilon: Float = 0.004
    /// The statistics' size, as a divisor of the frame's.
    static let downscale = 4
    /// The box radius as a fraction of the statistics' width: 16 texels at 4K, as fitted on the XDR stills.
    static let radiusFraction = 1.0 / 60.0
    /// The format of the coefficients the fragment shader samples bilinearly: half floats, which every GPU filters (32-bit
    /// float filtering isn't on every iOS / tvOS GPU). a and b lie in [0, 1], where half's step (≤ 0.0005) is far below
    /// √ε. The statistics before them stay 32-bit: the variance is E[I²] − E[I]², which half precision would cancel away.
    static let coefficientFormat = MTLPixelFormat.rg16Float

    private let statisticsPipeline: any MTLComputePipelineState
    private let coefficientsPipeline: any MTLComputePipelineState

    init?(device: any MTLDevice, library: any MTLLibrary) {
        guard let statistics = library.makeFunction(name: "contrastRecoveryStatistics"),
            let coefficients = library.makeFunction(name: "contrastRecoveryCoefficients"),
            let statisticsPipeline = try? device.makeComputePipelineState(function: statistics),
            let coefficientsPipeline = try? device.makeComputePipelineState(function: coefficients)
        else { return nil }
        self.statisticsPipeline = statisticsPipeline
        self.coefficientsPipeline = coefficientsPipeline
    }

    /// The textures and box filter of one frame size. Not shared between command buffers in flight at once: the layer's
    /// frames keep one (they are drawn one at a time), a still makes its own.
    final class Workspace {
        let width: Int
        let height: Int
        fileprivate let statistics: any MTLTexture
        fileprivate let boxedStatistics: any MTLTexture
        fileprivate let coefficients: any MTLTexture
        /// What the fragment shader samples: box means of the coefficients, in half floats (`coefficientFormat`).
        let boxedCoefficients: any MTLTexture
        fileprivate let box: MPSImageBox

        init?(device: any MTLDevice, frameWidth: Int, frameHeight: Int) {
            width = max((frameWidth + ContrastRecovery.downscale - 1) / ContrastRecovery.downscale, 1)
            height = max((frameHeight + ContrastRecovery.downscale - 1) / ContrastRecovery.downscale, 1)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg32Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            let sampledDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: ContrastRecovery.coefficientFormat, width: width, height: height, mipmapped: false)
            sampledDescriptor.usage = [.shaderRead, .shaderWrite]
            sampledDescriptor.storageMode = .private
            guard let statistics = device.makeTexture(descriptor: descriptor),
                let boxedStatistics = device.makeTexture(descriptor: descriptor),
                let coefficients = device.makeTexture(descriptor: descriptor),
                let boxedCoefficients = device.makeTexture(descriptor: sampledDescriptor)
            else { return nil }
            self.statistics = statistics
            self.boxedStatistics = boxedStatistics
            self.coefficients = coefficients
            self.boxedCoefficients = boxedCoefficients
            let radius = max(Int((Double(width) * ContrastRecovery.radiusFraction).rounded()), 2)
            box = MPSImageBox(device: device, kernelWidth: 2 * radius + 1, kernelHeight: 2 * radius + 1)
            box.edgeMode = .clamp
        }

        func fits(frameWidth: Int, frameHeight: Int) -> Bool {
            width == max((frameWidth + ContrastRecovery.downscale - 1) / ContrastRecovery.downscale, 1)
                && height == max((frameHeight + ContrastRecovery.downscale - 1) / ContrastRecovery.downscale, 1)
        }
    }

    /// Encodes the coefficients of the frame in `luma` / `chroma` (decoded with `uniforms`) into `workspace`'s
    /// `boxedCoefficients`.
    func encode(
        into commandBuffer: any MTLCommandBuffer, luma: any MTLTexture, chroma: any MTLTexture,
        uniforms: ToneMapUniforms, workspace: Workspace
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var uniforms = uniforms
        encoder.setComputePipelineState(statisticsPipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(workspace.statistics, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)
        dispatch(encoder, statisticsPipeline, workspace)
        encoder.endEncoding()

        workspace.box.encode(
            commandBuffer: commandBuffer, sourceTexture: workspace.statistics,
            destinationTexture: workspace.boxedStatistics)

        guard let coefficientsEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var epsilon = Self.epsilon
        coefficientsEncoder.setComputePipelineState(coefficientsPipeline)
        coefficientsEncoder.setTexture(workspace.boxedStatistics, index: 0)
        coefficientsEncoder.setTexture(workspace.coefficients, index: 1)
        coefficientsEncoder.setBytes(&epsilon, length: MemoryLayout<Float>.stride, index: 0)
        dispatch(coefficientsEncoder, coefficientsPipeline, workspace)
        coefficientsEncoder.endEncoding()

        workspace.box.encode(
            commandBuffer: commandBuffer, sourceTexture: workspace.coefficients,
            destinationTexture: workspace.boxedCoefficients)
    }

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState, _ workspace: Workspace
    ) {
        let width = pipeline.threadExecutionWidth
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(
            MTLSize(width: workspace.width, height: workspace.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }
}
