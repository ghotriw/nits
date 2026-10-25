/// Samples of a 4:2:0 bi-planar Y'CbCr frame (NV12, P010) on a sparse grid, for the frame average the reference white
/// follows (`FrameLuminanceMeter` in NitsCore). Here so it runs optimized in Debug too: taken on the display link for
/// every frame drawn, it cost ~1.7 ms of a 4K frame under `-Onone` and ~0.02 ms optimized.
public enum FrameSampling {
    /// The codes of `columns` × `rows` pixels at the centres of a grid over the frame, each over its whole code range
    /// ([0, 1]: luma, Cb, Cr), into `samples`, row by row.
    /// - Parameters:
    ///   - isTenBit: P010 (16-bit samples, codes in the high bits); else 8-bit.
    ///   - lumaStride, chromaStride: Bytes per row.
    public static func sampleBiPlanar(
        luma: UnsafeRawPointer, lumaStride: Int, chroma: UnsafeRawPointer, chromaStride: Int,
        width: Int, height: Int, chromaWidth: Int, chromaHeight: Int, isTenBit: Bool,
        columns: Int, rows: Int, into samples: UnsafeMutablePointer<SIMD3<Float>>
    ) {
        let scale: Float = isTenBit ? 1 / 65535 : 1 / 255
        for row in 0..<rows {
            let y = min((2 * row + 1) * height / (2 * rows), height - 1)
            let cy = min(y * chromaHeight / height, chromaHeight - 1)
            let lumaRow = luma.advanced(by: y * lumaStride)
            let chromaRow = chroma.advanced(by: cy * chromaStride)
            for column in 0..<columns {
                let x = min((2 * column + 1) * width / (2 * columns), width - 1)
                let cx = min(x * chromaWidth / width, chromaWidth - 1)
                let codes: SIMD3<Float>
                if isTenBit {
                    let l = lumaRow.assumingMemoryBound(to: UInt16.self)
                    let c = chromaRow.assumingMemoryBound(to: UInt16.self)
                    codes = SIMD3(Float(l[x]), Float(c[cx * 2]), Float(c[cx * 2 + 1]))
                } else {
                    let l = lumaRow.assumingMemoryBound(to: UInt8.self)
                    let c = chromaRow.assumingMemoryBound(to: UInt8.self)
                    codes = SIMD3(Float(l[x]), Float(c[cx * 2]), Float(c[cx * 2 + 1]))
                }
                samples[row * columns + column] = codes * scale
            }
        }
    }

    /// The mean and the maximum over `count` samples (codes as `sampleBiPlanar` gives them) of max(R', G', B') clamped
    /// to [0, 1]: for PQ, the PQ code of max(R, G, B). Y' = (luma - lumaOffset) · lumaScale, Cb / Cr = (code -
    /// chromaOffset) · chromaScale; R' = Y' + crToR · Cr, G' = Y' - cbToG · Cb - crToG · Cr, B' = Y' + cbToB · Cb.
    public static func maxNonLinearRGBMeanAndPeak(
        _ samples: UnsafePointer<SIMD3<Float>>, count: Int,
        lumaOffset: Float, lumaScale: Float, chromaOffset: Float, chromaScale: Float,
        crToR: Float, cbToG: Float, crToG: Float, cbToB: Float
    ) -> (mean: Float, peak: Float) {
        guard count > 0 else { return (0, 0) }
        var sum: Float = 0
        var top: Float = 0
        for i in 0..<count {
            let s = samples[i]
            let y = (s.x - lumaOffset) * lumaScale
            let cb = (s.y - chromaOffset) * chromaScale
            let cr = (s.z - chromaOffset) * chromaScale
            let peak = min(max(max(y + crToR * cr, y - cbToG * cb - crToG * cr, y + cbToB * cb), 0), 1)
            sum += peak
            top = max(top, peak)
        }
        return (sum / Float(count), top)
    }
}
