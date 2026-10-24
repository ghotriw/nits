import CFFmpeg
import CoreGraphics
import Foundation
import simd

/// How a decoded frame's samples are encoded; decides the thumbnail conversion path.
enum ThumbnailSourceEncoding: Equatable {
    enum Primaries: Equatable {
        case bt709
        case bt2020
        case displayP3
    }

    /// SDR R'G'B', tagged with its primaries and shown as-is.
    case sdr(Primaries)
    /// BT.2100 PQ, BT.2020 primaries.
    case pq
    /// BT.2100 HLG, BT.2020 primaries.
    case hlg
    /// Dolby Vision Profile 5: IPT-PQ-C2 base layer with no HDR10 / SDR fallback.
    case dolbyVisionIPT

    init(
        frame: UnsafeMutablePointer<AVFrame>,
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        isDolbyVisionProfile5: Bool
    ) {
        let colorSpace =
            frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED ? frame.pointee.colorspace : codecpar.pointee.color_space
        if isDolbyVisionProfile5 || colorSpace == AVCOL_SPC_IPT_C2 {
            self = .dolbyVisionIPT
            return
        }

        let transfer =
            frame.pointee.color_trc != AVCOL_TRC_UNSPECIFIED ? frame.pointee.color_trc : codecpar.pointee.color_trc
        let primaries =
            frame.pointee.color_primaries != AVCOL_PRI_UNSPECIFIED
            ? frame.pointee.color_primaries : codecpar.pointee.color_primaries

        if transfer == AVCOL_TRC_SMPTE2084 {
            self = .pq
        } else if transfer == AVCOL_TRC_ARIB_STD_B67 {
            self = .hlg
        } else if primaries == AVCOL_PRI_BT2020 || colorSpace == AVCOL_SPC_BT2020_NCL
            || colorSpace == AVCOL_SPC_BT2020_CL
        {
            self = .sdr(.bt2020)
        } else if primaries == AVCOL_PRI_SMPTE432 {
            self = .sdr(.displayP3)
        } else {
            self = .sdr(.bt709)
        }
    }

    /// Pixel format the scaler produces for this encoding. HDR keeps 16 bits per component so
    /// tone mapping doesn't band; Profile 5 stays YCbCr-shaped because swscale can't convert IPT.
    var scaledPixelFormat: AVPixelFormat {
        switch self {
        case .sdr: AV_PIX_FMT_RGBA
        case .pq, .hlg: AV_PIX_FMT_RGBA64LE
        case .dolbyVisionIPT: AV_PIX_FMT_YUV444P16LE
        }
    }
}

/// Scales decoded frames to thumbnail size and turns them into SDR `CGImage`s. The scaler is
/// rebuilt whenever the frame's format, dimensions or encoding change.
final class ThumbnailFrameConverter {
    let width: Int32
    let height: Int32
    private let isDolbyVisionProfile5: Bool
    private let scaled: UnsafeMutablePointer<AVFrame>
    private var swsCtx: UnsafeMutablePointer<SwsContext>?
    private var sourceFormat = AV_PIX_FMT_NONE
    private var sourceWidth: Int32 = 0
    private var sourceHeight: Int32 = 0
    private var encoding: ThumbnailSourceEncoding?

    init?(width: Int32, height: Int32, isDolbyVisionProfile5: Bool) {
        guard let scaled = av_frame_alloc() else { return nil }
        self.width = width
        self.height = height
        self.isDolbyVisionProfile5 = isDolbyVisionProfile5
        self.scaled = scaled
    }

    deinit {
        if let swsCtx {
            sws_freeContext(swsCtx)
        }
        var frame: UnsafeMutablePointer<AVFrame>? = scaled
        av_frame_free(&frame)
    }

    /// `dolbyVision`: the reshaping of a Profile 5 frame's RPU, which its IPT is composed with; `curve`: the tone
    /// curve of an HDR frame (its scene's peak and white).
    func makeImage(
        from frame: UnsafeMutablePointer<AVFrame>,
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        dolbyVision: DolbyVisionPixelReshaping? = nil,
        curve: ThumbnailToneMapper.Curve
    ) -> CGImage? {
        let format = AVPixelFormat(frame.pointee.format)
        let frameWidth = frame.pointee.width
        let frameHeight = frame.pointee.height
        guard frameWidth > 0, frameHeight > 0, format != AV_PIX_FMT_NONE else { return nil }

        let encoding = ThumbnailSourceEncoding(
            frame: frame,
            codecpar: codecpar,
            isDolbyVisionProfile5: isDolbyVisionProfile5
        )
        if swsCtx == nil || format != sourceFormat || frameWidth != sourceWidth || frameHeight != sourceHeight
            || encoding != self.encoding
        {
            guard rebuildScaler(for: frame, format: format, encoding: encoding, codecpar: codecpar) else {
                return nil
            }
        }
        guard let swsCtx else { return nil }

        let scaleRet = withUnsafePointer(to: &frame.pointee.data) { frameDataPtr in
            withUnsafePointer(to: &frame.pointee.linesize) { frameLinesizePtr in
                withUnsafeMutablePointer(to: &scaled.pointee.data) { scaledDataPtr in
                    withUnsafeMutablePointer(to: &scaled.pointee.linesize) { scaledLinesizePtr in
                        sws_scale(
                            swsCtx,
                            UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(frameDataPtr)),
                            UnsafePointer<Int32>(OpaquePointer(frameLinesizePtr)),
                            0,
                            frameHeight,
                            UnsafePointer<UnsafeMutablePointer<UInt8>?>(OpaquePointer(scaledDataPtr)),
                            UnsafePointer<Int32>(OpaquePointer(scaledLinesizePtr))
                        )
                    }
                }
            }
        }
        guard scaleRet > 0 else { return nil }

        let width = Int(width)
        let height = Int(height)
        switch encoding {
        case .sdr(let primaries):
            guard let plane = scaled.pointee.data.0 else { return nil }
            let bytesPerRow = Int(scaled.pointee.linesize.0)
            return Self.makeCGImage(
                pixels: Data(bytes: plane, count: bytesPerRow * height),
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                colorSpace: Self.colorSpace(for: primaries)
            )
        case .pq, .hlg, .dolbyVisionIPT:
            let fullRange = Self.isFullRange(frame: frame, codecpar: codecpar)
            guard
                let pixels = ThumbnailToneMapper.render(
                    scaled,
                    encoding: encoding,
                    width: width,
                    height: height,
                    fullRange: fullRange,
                    dolbyVision: dolbyVision,
                    curve: curve
                )
            else { return nil }
            return Self.makeCGImage(
                pixels: pixels,
                width: width,
                height: height,
                bytesPerRow: width * 4,
                colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
            )
        }
    }

    private func rebuildScaler(
        for frame: UnsafeMutablePointer<AVFrame>,
        format: AVPixelFormat,
        encoding: ThumbnailSourceEncoding,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        if let swsCtx {
            sws_freeContext(swsCtx)
        }
        swsCtx = nil
        self.encoding = nil

        let scaledFormat = encoding.scaledPixelFormat
        av_frame_unref(scaled)
        scaled.pointee.format = scaledFormat.rawValue
        scaled.pointee.width = width
        scaled.pointee.height = height
        guard av_frame_get_buffer(scaled, 0) >= 0 else { return false }

        swsCtx = sws_getContext(
            frame.pointee.width,
            frame.pointee.height,
            format,
            width,
            height,
            scaledFormat,
            Int32(SWS_BILINEAR.rawValue),
            nil,
            nil,
            nil
        )
        guard let swsCtx else { return false }
        // IPT stays in its own component space; RGB outputs get the source matrix and range.
        if encoding != .dolbyVisionIPT {
            Self.configureColorspace(swsCtx: swsCtx, frame: frame, codecpar: codecpar)
        }

        sourceFormat = format
        sourceWidth = frame.pointee.width
        sourceHeight = frame.pointee.height
        self.encoding = encoding
        return true
    }

    private static func configureColorspace(
        swsCtx: UnsafeMutablePointer<SwsContext>,
        frame: UnsafeMutablePointer<AVFrame>,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) {
        let colorSpace =
            frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED ? frame.pointee.colorspace : codecpar.pointee.color_space
        let colorPrimaries =
            frame.pointee.color_primaries != AVCOL_PRI_UNSPECIFIED
            ? frame.pointee.color_primaries : codecpar.pointee.color_primaries
        let isBT2020 =
            colorSpace == AVCOL_SPC_BT2020_NCL || colorSpace == AVCOL_SPC_BT2020_CL
            || colorPrimaries == AVCOL_PRI_BT2020
        let invTable =
            isBT2020
            ? sws_getCoefficients(SWS_CS_BT2020)
            : (colorSpace == AVCOL_SPC_BT709 ? sws_getCoefficients(SWS_CS_ITU709) : sws_getCoefficients(SWS_CS_DEFAULT))
        let srcRange: Int32 = isFullRange(frame: frame, codecpar: codecpar) ? 1 : 0

        _ = sws_setColorspaceDetails(
            swsCtx,
            invTable,
            srcRange,
            sws_getCoefficients(SWS_CS_DEFAULT),
            1,  // output full range RGB
            0,
            1 << 16,
            1 << 16
        )
    }

    /// Frame range, falling back to the stream's when the frame leaves it unspecified.
    private static func isFullRange(
        frame: UnsafeMutablePointer<AVFrame>,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        let range =
            frame.pointee.color_range != AVCOL_RANGE_UNSPECIFIED
            ? frame.pointee.color_range : codecpar.pointee.color_range
        return range == AVCOL_RANGE_JPEG
    }

    private static func colorSpace(for primaries: ThumbnailSourceEncoding.Primaries) -> CGColorSpace? {
        switch primaries {
        case .bt709: CGColorSpace(name: CGColorSpace.sRGB)
        case .bt2020: CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        }
    }

    private static func makeCGImage(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        colorSpace: CGColorSpace?
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// CPU tone mapping of 16-bit HDR thumbnails (PQ, HLG, Dolby Vision IPT) to 8-bit SDR Display P3, as the player's
/// Metal path does it (`HDRToneMapping.metal`): the BT.2390 black level lift, the scene's reference white
/// (`ToneMapController.sceneTargetNits`) and sRGB encoding, with a soft shoulder of its own in place of BT.2390's knee.
enum ThumbnailToneMapper {
    /// Nominal peak of the BT.2100 HLG reference display.
    static let hlgPeakNits: Float = 1000
    /// The display black the shadows are lifted towards, as a fraction of white: `displayBlackToWhite` in
    /// `HDRToneMapping.metal`.
    static let displayBlackToWhite: Float = 0.0006

    /// The curve of one frame: its scene's peak and reference white, and the black level lift they give.
    struct Curve {
        let whiteNits: Float
        let peakPQ: Float
        /// The lift's `b`: the display black in PQ normalized to the source range [0, peak].
        let blackLift: Float
        /// The shoulder's `k`, so that 0.6 + e / (1 + k e) reaches 1.0 at the peak (e = peak / white - 0.6).
        let shoulder: Float

        init(peakNits: Float, whiteNits: Float) {
            self.whiteNits = whiteNits
            shoulder = max(1 / 0.4 - 1 / max(peakNits / whiteNits - 0.6, 1e-3), 0)
            peakPQ = ThumbnailToneMapper.nitsToPQ(max(peakNits, 100))
            blackLift = ThumbnailToneMapper.nitsToPQ(whiteNits * ThumbnailToneMapper.displayBlackToWhite) / peakPQ
        }

        /// ITU-R BT.2390 black level lift (EETF step 4) of linear nits, as `liftBlackLevel` in the shader.
        @inline(__always)
        func liftBlackLevel(_ nits: Float) -> Float {
            let e = ThumbnailToneMapper.nitsToPQ(nits) / peakPQ
            let rest = max(1 - e, 0)
            return ThumbnailToneMapper.pqToNits((e + blackLift * rest * rest * rest * rest) * peakPQ)
        }
    }

    /// PQ code value (16-bit) → absolute luminance in nits.
    private static let pqLUT: [Float] = (0...65535).map { pqToNits(Float($0) / 65535) }
    /// HLG code value (16-bit) → normalised scene-linear light.
    private static let hlgLUT: [Float] = (0...65535).map { hlgToSceneLinear(Float($0) / 65535) }
    /// Linear [0, 1] → 8-bit sRGB, the transfer of the Display P3 the image is tagged with.
    private static let srgbLUT: [UInt8] = (0...16383).map {
        let c = Float($0) / 16383
        let encoded = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (encoded * 255).rounded())))
    }

    static func nitsToPQ(_ nits: Float) -> Float {
        let m1: Float = 2610 / 16384
        let m2: Float = 2523 / 32
        let c1: Float = 3424 / 4096
        let c2: Float = 2413 / 128
        let c3: Float = 2392 / 128
        let y = pow(max(nits, 0) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    static func pqToNits(_ value: Float) -> Float {
        let m1: Float = 2610 / 16384
        let m2: Float = 2523 / 32
        let c1: Float = 3424 / 4096
        let c2: Float = 2413 / 128
        let c3: Float = 2392 / 128
        let p = pow(max(value, 0), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    static func hlgToSceneLinear(_ value: Float) -> Float {
        let a: Float = 0.17883277
        let b: Float = 0.28466892
        let c: Float = 0.55991073
        return value <= 0.5 ? value * value / 3 : (exp((value - c) / a) + b) / 12
    }

    /// Dolby Vision Profile 5 IPT-PQ-C2 → linear BT.2020 nits using default IPT matrices without dynamic RPU reshaping,
    /// for a keyframe whose RPU is missing or has no curves to apply. Inputs are normalised: I in [0, 1], P / T centred
    /// on 0. The base layer alone can differ much in contrast and colour from the reshaped picture.
    static func nitsFromIPT(i: Float, ct: Float, cp: Float) -> SIMD3<Float> {
        let lmsPrime = DolbyVisionColorScience.defaultIptToLms * SIMD3(i, ct, cp)
        let lms = SIMD3(pqLUT[lutIndex(lmsPrime.x)], pqLUT[lutIndex(lmsPrime.y)], pqLUT[lutIndex(lmsPrime.z)])
        return simd_max(DolbyVisionColorScience.defaultLmsToRgb * lms, .zero)
    }

    /// Tone-maps the scaled 16-bit frame into packed 8-bit RGBX, or `nil` for an SDR encoding; a Profile 5 frame with
    /// `dolbyVision` through its RPU's curves and matrices.
    static func render(
        _ scaled: UnsafeMutablePointer<AVFrame>,
        encoding: ThumbnailSourceEncoding,
        width: Int,
        height: Int,
        fullRange: Bool,
        dolbyVision: DolbyVisionPixelReshaping? = nil,
        curve: ThumbnailToneMapper.Curve
    ) -> Data? {
        var output = Data(count: width * height * 4)
        let rendered: Bool = output.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            switch encoding {
            case .pq, .hlg:
                guard let plane = scaled.pointee.data.0 else { return false }
                let stride = Int(scaled.pointee.linesize.0)
                for y in 0..<height {
                    let row = UnsafeRawPointer(plane + y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let px = row + x * 4
                        let rgb: SIMD3<Float>
                        if encoding == .pq {
                            rgb = SIMD3(pqLUT[Int(px[0])], pqLUT[Int(px[1])], pqLUT[Int(px[2])])
                        } else {
                            // BT.2100 HLG OOTF: display light = Lw · Ys^(γ−1) · E, γ = 1.2 at 1000 nits.
                            let scene = SIMD3(hlgLUT[Int(px[0])], hlgLUT[Int(px[1])], hlgLUT[Int(px[2])])
                            let ys = 0.2627 * scene.x + 0.6780 * scene.y + 0.0593 * scene.z
                            rgb = ys > 0 ? scene * (hlgPeakNits * pow(ys, 0.2)) : .zero
                        }
                        writeSDR(nits2020: rgb, curve: curve, to: out + (y * width + x) * 4)
                    }
                }
            case .dolbyVisionIPT:
                guard let iPlane = scaled.pointee.data.0, let ctPlane = scaled.pointee.data.1,
                    let cpPlane = scaled.pointee.data.2
                else { return false }
                // swscale widens 10-bit samples to 16 bits by bit replication, so v / 65535 ≈ v10 / 1023.
                let lumaOffset: Float = fullRange ? 0 : 64 / 1023
                let lumaScale: Float = fullRange ? 1 : 1023 / 876
                let chromaScale: Float = fullRange ? 1 : 1023 / 896
                let chromaOffset: Float = 512 / 1023
                for y in 0..<height {
                    let iRow = UnsafeRawPointer(iPlane + y * Int(scaled.pointee.linesize.0))
                        .assumingMemoryBound(to: UInt16.self)
                    let ctRow = UnsafeRawPointer(ctPlane + y * Int(scaled.pointee.linesize.1))
                        .assumingMemoryBound(to: UInt16.self)
                    let cpRow = UnsafeRawPointer(cpPlane + y * Int(scaled.pointee.linesize.2))
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        if let dolbyVision {
                            // The RPU's curves take the codewords themselves, whatever the range, as the shader does.
                            let lmsPrime = dolbyVision.lmsPrime(
                                raw: SIMD3(Float(iRow[x]), Float(ctRow[x]), Float(cpRow[x])) / 65535)
                            let lms = SIMD3(
                                pqLUT[lutIndex(lmsPrime.x)], pqLUT[lutIndex(lmsPrime.y)], pqLUT[lutIndex(lmsPrime.z)])
                            writeSDR(
                                nits2020: simd_max(dolbyVision.lmsToRgb * lms, .zero), curve: curve,
                                to: out + (y * width + x) * 4)
                            continue
                        }
                        let rgb = nitsFromIPT(
                            i: (Float(iRow[x]) / 65535 - lumaOffset) * lumaScale,
                            ct: (Float(ctRow[x]) / 65535 - chromaOffset) * chromaScale,
                            cp: (Float(cpRow[x]) / 65535 - chromaOffset) * chromaScale
                        )
                        writeSDR(nits2020: rgb, curve: curve, to: out + (y * width + x) * 4)
                    }
                }
            case .sdr:
                return false
            }
            return true
        }
        return rendered ? output : nil
    }

    /// Linear BT.2020 nits → black level lift → BT.2020-to-P3 gamut conversion → SDR tone curve → sRGB RGBX.
    @inline(__always)
    static func writeSDR(nits2020 source: SIMD3<Float>, curve: Curve, to out: UnsafeMutablePointer<UInt8>) {
        let rgb = SIMD3(
            curve.liftBlackLevel(source.x), curve.liftBlackLevel(source.y), curve.liftBlackLevel(source.z))
        let r = max(1.343578 * rgb.x - 0.282180 * rgb.y - 0.061399 * rgb.z, 0)
        let g = max(-0.065297 * rgb.x + 1.075788 * rgb.y - 0.010490 * rgb.z, 0)
        let b = max(0.002822 * rgb.x - 0.019598 * rgb.y + 1.016777 * rgb.z, 0)
        out[3] = 255

        let peak = max(r, max(g, b))
        guard peak > 1e-4 else {
            out[0] = 0
            out[1] = 0
            out[2] = 0
            return
        }

        // Linear up to 0.6 of reference white, then a shoulder of slope 1 at its start that brings the scene's peak to
        // 1.0, as the player's curve does (a peak at or below white leaves it linear). What exceeds the peak clips.
        let x = peak / curve.whiteNits
        let excess = x - 0.6
        let mapped = excess <= 0 ? x : 0.6 + excess / (1 + excess * curve.shoulder)
        let scale = (mapped / x) / curve.whiteNits
        out[0] = srgbLUT[srgbIndex(r * scale)]
        out[1] = srgbLUT[srgbIndex(g * scale)]
        out[2] = srgbLUT[srgbIndex(b * scale)]
    }

    @inline(__always)
    private static func lutIndex(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 65535).rounded())
    }

    @inline(__always)
    private static func srgbIndex(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 16383).rounded())
    }
}
