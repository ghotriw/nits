import CoreVideo
import Foundation
import NitsKernels
import simd

/// The average brightness of a decoded HDR frame as Dolby Vision's L1 average is defined: the mean of max(R, G, B) in PQ
/// over the picture. The reference white follows it (`ToneMapController.measuredTargetNits`). Fitted against the XDR
/// presentation of 34 scenes of three titles, the white that matches it tracks the scene's average, not its peak, and
/// measured on the frame it serves titles whose L1 is static, or absent (HDR10), as well as those with a dynamic one.
/// The brightest sample keeps the curve's peak from falling under the picture's (`ToneMapController.applyFrame`).
///
/// The whole frame counts, letterbox bars and black included, as in the fit of the white. A known limit, not a finding
/// that bars belong in the average: a letterboxed film gets a lower white than without its bars, and the fit had too few
/// letterboxed titles to correct that. See "Reference white" in docs/ARCHITECTURE.md.
///
/// Sampled on a sparse grid on the CPU from the frame about to be drawn, so the white is that frame's own: a GPU pass
/// would hand its result back a frame late, which shows as a flash at cuts. For PQ the maximum of R'G'B' is already
/// PQ(max(R, G, B)), so a sample is a matrix and a max. The sampling and the PQ path are in NitsKernels (`FrameSampling`),
/// optimized in Debug too: ~0.02 ms a 4K frame. HLG and Profile 5 go through NitsCore's per-sample formulas (Dolby
/// Vision reshaping lives here): ~0.1 ms optimized, ~2 ms in Debug.
struct FrameLuminanceMeter: Sendable {
    /// How the frame's samples become light.
    enum Signal: Sendable {
        /// BT.2100 PQ Y'CbCr.
        case pq
        /// BT.2100 HLG Y'CbCr, through the reference OOTF at 1000 nits.
        case hlg
        /// Dolby Vision Profile 5 IPT-PQ-c2, through the RPU's reshaping when it has curves.
        case dolbyVisionIPT
    }

    let signal: Signal
    /// The Y'CbCr matrix is BT.709 rather than BT.2020's.
    let isBT709: Bool

    /// A frame's max(R, G, B) over the grid, in PQ.
    struct Measurement: Sendable, Equatable {
        /// The mean: Dolby Vision's L1 average.
        let averagePQ: Float
        /// The brightest sample. Small highlights between grid points escape it, but not an area as large as a sky,
        /// which an L1 max below it (some Dolby Vision encodes) would clip to white.
        let peakPQ: Float

        var averageNits: Float { ThumbnailToneMapper.pqToNits(averagePQ) }
        var peakNits: Float { ThumbnailToneMapper.pqToNits(peakPQ) }
    }

    private static let columns = 64
    private static let rows = 36

    /// The frame's average and peak of max(R, G, B), or nil for a buffer it can't read: anything but 4:2:0 biplanar 8-
    /// or 10-bit, which the renderer takes too.
    func measure(_ buffer: CVPixelBuffer, reshaping: DolbyVisionPixelReshaping?) -> Measurement? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isTenBit =
            format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let isEightBit =
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isTenBit || isEightBit, CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        let isFullRange =
            format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard width > 0, height > 0, chromaWidth > 0, chromaHeight > 0 else { return nil }
        // Luma and the two chroma codes of each sample, over their whole code range ([0, 1]), as the shader samples them.
        let count = Self.rows * Self.columns
        var samples = [SIMD3<Float>](repeating: .zero, count: count)
        samples.withUnsafeMutableBufferPointer {
            FrameSampling.sampleBiPlanar(
                luma: lumaBase, lumaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chroma: chromaBase,
                chromaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), width: width, height: height,
                chromaWidth: chromaWidth, chromaHeight: chromaHeight, isTenBit: isTenBit, columns: Self.columns,
                rows: Self.rows, into: $0.baseAddress!)
        }

        // Normalization of the codes to Y' in [0, 1] and Cb / Cr around 0, as `nitsFromYUV` in the shader.
        let lumaOffset: Float = isFullRange ? 0 : (isTenBit ? 4096 / 65535 : 16 / 255)
        let lumaScale: Float = isFullRange ? 1 : (isTenBit ? 65535 / 56064 : 255 / 219)
        let chromaOffset: Float = isTenBit ? 32768 / 65535 : 128 / 255
        let chromaScale: Float = isFullRange ? 1 : (isTenBit ? 65535 / 57344 : 255 / 224)

        if signal == .pq {
            let (crToR, cbToG, crToG, cbToB): (Float, Float, Float, Float) =
                isBT709 ? (1.5748, 0.187324, 0.468124, 1.8556) : (1.4746, 0.164553, 0.571353, 1.8814)
            let (mean, peak) = FrameSampling.maxNonLinearRGBMeanAndPeak(
                samples, count: count, lumaOffset: lumaOffset, lumaScale: lumaScale, chromaOffset: chromaOffset,
                chromaScale: chromaScale, crToR: crToR, cbToG: cbToG, crToG: crToG, cbToB: cbToB)
            return Measurement(averagePQ: mean, peakPQ: peak)
        }
        var sum: Float = 0
        var peak: Float = 0
        for raw in samples {
            let yuv = SIMD3(
                (raw.x - lumaOffset) * lumaScale, (raw.y - chromaOffset) * chromaScale,
                (raw.z - chromaOffset) * chromaScale)
            let value = maxPQ(raw: raw, yuv: yuv, reshaping: reshaping)
            sum += value
            peak = max(peak, value)
        }
        return Measurement(averagePQ: sum / Float(count), peakPQ: peak)
    }

    /// PQ of max(R, G, B) of one sample: `raw` its codes over their whole range, `yuv` normalized.
    private func maxPQ(raw: SIMD3<Float>, yuv: SIMD3<Float>, reshaping: DolbyVisionPixelReshaping?) -> Float {
        switch signal {
        case .pq:
            preconditionFailure("PQ frames are measured by FrameSampling.maxNonLinearRGBMeanAndPeak")
        case .hlg:
            let e = simd_clamp(nonLinearRGB(yuv), .zero, SIMD3(repeating: 1))
            let scene = SIMD3(
                ThumbnailToneMapper.hlgToSceneLinear(e.x), ThumbnailToneMapper.hlgToSceneLinear(e.y),
                ThumbnailToneMapper.hlgToSceneLinear(e.z))
            let ys = simd_dot(scene, SIMD3(0.2627, 0.6780, 0.0593))
            let nits = ys > 0 ? scene * (ThumbnailToneMapper.hlgPeakNits * pow(ys, 0.2)) : .zero
            return ThumbnailToneMapper.nitsToPQ(nits.max())
        case .dolbyVisionIPT:
            let rgb: SIMD3<Float>
            if let reshaping {
                // The RPU's curves take the codewords themselves, whatever the range, as the shader does.
                let lmsPrime = reshaping.lmsPrime(raw: raw)
                let lms = SIMD3(
                    ThumbnailToneMapper.pqToNits(lmsPrime.x), ThumbnailToneMapper.pqToNits(lmsPrime.y),
                    ThumbnailToneMapper.pqToNits(lmsPrime.z))
                rgb = reshaping.lmsToRgb * lms
            } else {
                rgb = ThumbnailToneMapper.nitsFromIPT(i: yuv.x, ct: yuv.y, cp: yuv.z)
            }
            return ThumbnailToneMapper.nitsToPQ(max(rgb.max(), 0))
        }
    }

    /// R'G'B' of normalized Y'CbCr by the stream's matrix (BT.2020 non-constant luminance, or BT.709).
    private func nonLinearRGB(_ yuv: SIMD3<Float>) -> SIMD3<Float> {
        isBT709
            ? SIMD3(yuv.x + 1.5748 * yuv.z, yuv.x - 0.187324 * yuv.y - 0.468124 * yuv.z, yuv.x + 1.8556 * yuv.y)
            : SIMD3(yuv.x + 1.4746 * yuv.z, yuv.x - 0.164553 * yuv.y - 0.571353 * yuv.z, yuv.x + 1.8814 * yuv.y)
    }
}
