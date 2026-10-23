#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 texCoords;
};

// sourceRect: the part of the frame drawn, normalized with the origin at the top left (xy origin, zw size).
vertex VertexOutput hdrVertexShader(uint vertexID [[vertex_id]], constant float4 &sourceRect [[buffer(0)]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOutput out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoords = sourceRect.xy + texCoords[vertexID] * sourceRect.zw;
    return out;
}

// Dolby Vision Profile 5 reshaping (the RPU's curves per I / P / T component) and colour matrices
// (`ToneMapUniforms.DolbyVisionReshaping` in Swift). The defaults are IPT-PQ-c2 without reshaping.
struct DolbyVisionReshaping {
    uint isActive;                       // 1: the curves reshape the decoded codewords; 0: normalize them by range
    float3x3 iptToLms;                   // IPT -> LMS': the RPU's ycc_to_rgb_matrix, else IPT-PQ-c2's
    float3 iptOffset;                    // subtracted from the reshaped I / P / T (ycc_to_rgb_offset)
    float3x3 lmsToRgb;                   // LMS -> BT.2020 linear RGB, from the RPU's rgb_to_lms_matrix when present
    uint3 pieceCounts;                   // polynomial pieces of I, P, T; 0 for an MMR component
    uint3 mmrOrders;                     // MMR order of P (.y) and T (.z); 0 for a polynomial component
    float3 mmrConstants;                 // MMR constant of P (.y) and T (.z)
    float3 pivotMax;                     // upper end of each component's curve
    float4 pivots[3][2];                 // the 8 pivots of each component
    float4 polyCoeffs[3][8];             // (c0, c1, c2, 0) of each piece of each component
    float4 mmrCoeffs[2][6];              // MMR coefficients of P and T: 7 per order
};

struct ToneMapUniforms {
    float targetNits;                    // 203.0
    float sourcePeakNits;                // 1000.0
    float outputExposure;                // 1.0
    float outputSaturation;              // 1.0
    float outputWarmCorrection;          // 0.0
    float outputHighlightCompression;    // 0.0
    float outputShadowDetail;            // 0.0
    float outputShadowLift;              // 0.0
    float outputSharpness;               // 0.0 to 1.0 (default 0.5 for CAS)
    uint colorPrimaries;                 // 0: BT.2020, 1: BT.709, 2: DCI-P3 / P3-D65
    uint transferFunction;               // 0: PQ (ST 2084), 1: HLG, 2: BT.709 / SDR Gamma
    uint bitDepth;                       // 8 or 10
    uint isFullRange;                    // 0: Video Range, 1: Full Range
    uint colorSpaceMode;                 // 0: Standard YCbCr BT.2020, 1: BT.709, 2: Dolby Vision IPT / ICtCp
    uint hasDoviL2Trim;                  // 0: none, 1: authored L2 SDR trim active
    float doviTrimSlope;                 // L2 slope
    float doviTrimOffset;                // L2 offset
    float doviTrimPower;                 // L2 power
    float doviTrimSaturation;            // L2 saturation gain
    float doviTrimTargetNits;            // L2 target display peak (~100 nits)
    DolbyVisionReshaping doviReshaping;  // Dolby Vision Profile 5 reshaping and colour matrices
};

// PQ (SMPTE ST 2084) electro-optical transfer functions (EOTF / Inverse EOTF)
float3 pqToNits(float3 value) {
    constexpr float m1 = 2610.0 / 16384.0;
    constexpr float m2 = 2523.0 / 32.0;
    constexpr float c1 = 3424.0 / 4096.0;
    constexpr float c2 = 2413.0 / 128.0;
    constexpr float c3 = 2392.0 / 128.0;
    float3 p = pow(max(value, 0.0), 1.0 / m2);
    float3 ratio = max(p - c1, 0.0) / max(c2 - c3 * p, 1e-6);
    return 10000.0 * pow(ratio, 1.0 / m1);
}

float nitsToPQ(float value) {
    constexpr float m1 = 2610.0 / 16384.0;
    constexpr float m2 = 2523.0 / 32.0;
    constexpr float c1 = 3424.0 / 4096.0;
    constexpr float c2 = 2413.0 / 128.0;
    constexpr float c3 = 2392.0 / 128.0;
    float powered = pow(clamp(value / 10000.0, 0.0, 1.0), m1);
    return pow((c1 + c2 * powered) / (1.0 + c3 * powered), m2);
}

float3 nitsToPQ(float3 value) {
    constexpr float m1 = 2610.0 / 16384.0;
    constexpr float m2 = 2523.0 / 32.0;
    constexpr float c1 = 3424.0 / 4096.0;
    constexpr float c2 = 2413.0 / 128.0;
    constexpr float c3 = 2392.0 / 128.0;
    float3 powered = pow(clamp(value / 10000.0, 0.0, 1.0), float3(m1));
    return pow((c1 + c2 * powered) / (1.0 + c3 * powered), float3(m2));
}

// BT.2020 YUV -> Optical Nits (supports both 8-bit and 10-bit, video and full range)
float3 nitsFromYUV(float y, float2 uv, constant ToneMapUniforms &uniforms) {
    float Y_norm, Cb_norm, Cr_norm;
    if (uniforms.bitDepth == 8) {
        if (uniforms.isFullRange == 1) {
            Y_norm  = y;
            Cb_norm = uv.x - (128.0 / 255.0);
            Cr_norm = uv.y - (128.0 / 255.0);
        } else {
            Y_norm  = (y - (16.0 / 255.0)) / (219.0 / 255.0);
            Cb_norm = (uv.x - (128.0 / 255.0)) / (224.0 / 255.0);
            Cr_norm = (uv.y - (128.0 / 255.0)) / (224.0 / 255.0);
        }
    } else {
        // 10-bit MSB normalized inputs in .r16Unorm / .rg16Unorm
        if (uniforms.isFullRange == 1) {
            Y_norm  = y;
            Cb_norm = uv.x - (32768.0 / 65535.0);
            Cr_norm = uv.y - (32768.0 / 65535.0);
        } else {
            Y_norm  = (y - (4096.0 / 65535.0)) / (56064.0 / 65535.0);
            Cb_norm = (uv.x - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
            Cr_norm = (uv.y - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
        }
    }

    float3 nonlinear2020 = float3(
        Y_norm + 1.4746 * Cr_norm,
        Y_norm - 0.164553 * Cb_norm - 0.571353 * Cr_norm,
        Y_norm + 1.8814 * Cb_norm
    );
    return pqToNits(clamp(nonlinear2020, 0.0, 1.0));
}

// One component's piecewise polynomial curve (ETSI GS CCM 001 5.4.2.3.2) of `x`, the codeword normalized to [0, 1].
float evalDoviCurve(
    float x,
    uint numPieces,
    constant float4 *pivotVectors,
    float pivotMax,
    constant float4 *coeffs
) {
    if (numPieces == 0) {
        return clamp(x, 0.0, 1.0);
    }
    constant float *pivots = (constant float *)pivotVectors;
    float xc = clamp(x, pivots[0], pivotMax);
    uint piece = 0;
    for (uint i = 1; i < numPieces && i < 8; ++i) {
        if (xc >= pivots[i]) {
            piece = i;
        }
    }
    float4 c = coeffs[piece];
    return clamp(c.x + xc * (c.y + xc * c.z), 0.0, 1.0);
}

// Multivariate Multiple Regression (MMR) chroma reshaping (ETSI GS CCM 001 5.4.2.3.3)
float evalDoviMMR(
    float3 s,
    uint order,
    float mmrConstant,
    constant float4 *mmrCoeffs
) {
    float res = mmrConstant;
    float s0 = s.x, s1 = s.y, s2 = s.z;
    float s0_k = s0, s1_k = s1, s2_k = s2;
    constant float *coefs = (constant float *)mmrCoeffs;
    for (uint k = 0; k < order && k < 3; ++k) {
        float s01 = s0_k * s1_k;
        float s02 = s0_k * s2_k;
        float s12 = s1_k * s2_k;
        float s012 = s01 * s2_k;
        uint base = k * 7;
        res += coefs[base + 0] * s0_k;
        res += coefs[base + 1] * s1_k;
        res += coefs[base + 2] * s2_k;
        res += coefs[base + 3] * s01;
        res += coefs[base + 4] * s02;
        res += coefs[base + 5] * s12;
        res += coefs[base + 6] * s012;
        s0_k *= s0;
        s1_k *= s1;
        s2_k *= s2;
    }
    return clamp(res, 0.0, 1.0);
}

// The reshaped component `c` (1: P, 2: T) of `raw`: by MMR when it has an order, else by its polynomial curve.
float reshapeDoviChroma(float3 raw, uint c, constant DolbyVisionReshaping &r) {
    if (r.mmrOrders[c] != 0) {
        return evalDoviMMR(raw, r.mmrOrders[c], r.mmrConstants[c], r.mmrCoeffs[c - 1]);
    }
    return evalDoviCurve(raw[c], r.pieceCounts[c], r.pivots[c], r.pivotMax[c], r.polyCoeffs[c]);
}

// Dolby Vision Profile 5: IPT-PQ-c2 -> Linear BT.2020 Nits
// Plane 0 is I (Intensity), Plane 1 is P (Protan) and T (Tritan)
float3 nitsFromIPT(float y, float2 uv, constant ToneMapUniforms &uniforms) {
    constant DolbyVisionReshaping &r = uniforms.doviReshaping;
    float3 ipt;
    if (r.isActive != 0) {
        float3 raw = float3(y, uv.x, uv.y);
        if (uniforms.bitDepth != 8) {
            // 10-bit MSB-aligned P010 in .r16Unorm / .rg16Unorm: 1023 << 6 = 65472
            raw = clamp(raw * (65535.0 / 65472.0), 0.0, 1.0);
        }
        float reshapedI = evalDoviCurve(raw.x, r.pieceCounts.x, r.pivots[0], r.pivotMax.x, r.polyCoeffs[0]);
        ipt = float3(reshapedI, reshapeDoviChroma(raw, 1, r), reshapeDoviChroma(raw, 2, r)) - r.iptOffset;
    } else {
        // Without curves the base layer is normalized by its range and centred by fixed constants, not by the RPU's
        // ycc_to_rgb_offset, which applies to the reshaped signal (an RPU matrix still applies: an approximation).
        float I_norm, P_norm, T_norm;
        if (uniforms.bitDepth == 8) {
            if (uniforms.isFullRange == 1) {
                I_norm = y;
                P_norm = uv.x - (128.0 / 255.0);
                T_norm = uv.y - (128.0 / 255.0);
            } else {
                I_norm = (y - (16.0 / 255.0)) / (219.0 / 255.0);
                P_norm = (uv.x - (128.0 / 255.0)) / (224.0 / 255.0);
                T_norm = (uv.y - (128.0 / 255.0)) / (224.0 / 255.0);
            }
        } else {
            // 10-bit MSB normalized inputs in .r16Unorm / .rg16Unorm
            if (uniforms.isFullRange == 1) {
                I_norm = y * (65535.0 / 65472.0);
                P_norm = uv.x * (65535.0 / 65472.0) - (512.0 / 1023.0);
                T_norm = uv.y * (65535.0 / 65472.0) - (512.0 / 1023.0);
            } else {
                I_norm = (y - (4096.0 / 65535.0)) / (56064.0 / 65535.0);
                P_norm = (uv.x - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
                T_norm = (uv.y - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
            }
        }
        ipt = float3(I_norm, P_norm, T_norm);
    }

    // IPT -> LMS' (non-linear), PQ EOTF -> linear LMS, LMS -> BT.2020 linear RGB
    float3 lms_linear = pqToNits(clamp(r.iptToLms * ipt, 0.0, 1.0));
    return max(r.lmsToRgb * lms_linear, 0.0);
}

// HLG (ARIB STD-B67 / ITU-R BT.2100) -> Optical Nits
float3 nitsFromHLG(float y, float2 uv, constant ToneMapUniforms &uniforms) {
    float Y_norm, Cb_norm, Cr_norm;
    if (uniforms.bitDepth == 8) {
        if (uniforms.isFullRange == 1) {
            Y_norm  = y;
            Cb_norm = uv.x - (128.0 / 255.0);
            Cr_norm = uv.y - (128.0 / 255.0);
        } else {
            Y_norm  = (y - (16.0 / 255.0)) / (219.0 / 255.0);
            Cb_norm = (uv.x - (128.0 / 255.0)) / (224.0 / 255.0);
            Cr_norm = (uv.y - (128.0 / 255.0)) / (224.0 / 255.0);
        }
    } else {
        if (uniforms.isFullRange == 1) {
            Y_norm  = y;
            Cb_norm = uv.x - (32768.0 / 65535.0);
            Cr_norm = uv.y - (32768.0 / 65535.0);
        } else {
            Y_norm  = (y - (4096.0 / 65535.0)) / (56064.0 / 65535.0);
            Cb_norm = (uv.x - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
            Cr_norm = (uv.y - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
        }
    }

    // BT.2020 YUV -> Non-linear HLG RGB [0, 1]
    float3 nonLinear2020 = float3(
        Y_norm + 1.4746 * Cr_norm,
        Y_norm - 0.164553 * Cb_norm - 0.571353 * Cr_norm,
        Y_norm + 1.8814 * Cb_norm
    );
    float3 Ep = clamp(nonLinear2020, 0.0, 1.0);

    // HLG Inverse OETF (BT.2100): E' -> Linear scene light E
    // a = 0.17883277, b = 1 - 4a = 0.28466892, c = 0.55991073
    constexpr float a = 0.17883277;
    constexpr float b = 0.28466892;
    constexpr float c = 0.55991073;

    float3 E = select(
        (Ep * Ep) / 3.0,
        (exp((Ep - c) / a) + b) / 12.0,
        Ep > 0.5
    );

    // HLG OOTF (Opto-Optical Transfer Function): Scene light -> Display light in Nits
    // Target nominal peak display luminance Lw (default reference 1000 nits)
    float Lw = max(uniforms.sourcePeakNits, 1000.0);
    // Display gamma according to ITU-R BT.2100: gamma = 1.2 + 0.42 * log10(Lw / 1000.0)
    float gamma = 1.2 + 0.42 * log10(max(Lw / 1000.0, 0.1));
    float Ys = dot(E, float3(0.2627, 0.6780, 0.0593));
    float ootfScale = pow(max(Ys, 1e-6), gamma - 1.0);

    return Lw * ootfScale * E;
}

// ITU-R BT.2390 EETF with mpv's desaturation; defined in BT2390ToneMapping.metal (LGPL-2.1-or-later).
float3 mpvBT2390(float3 color, float sourcePeakNits, float sdrWhiteNits);

// BT.2020 Linear to Display P3 Linear (Column-major in Metal)
float3 bt2020_to_display_p3(float3 c) {
    float3x3 m = float3x3(
        float3( 1.343578, -0.065297,  0.002822), // Column 0
        float3(-0.282180,  1.075788, -0.019598), // Column 1
        float3(-0.061399, -0.010490,  1.016777)  // Column 2
    );
    return max(m * c, 0.0);
}

// Exposure compensation
float3 applyOutputExposure(float3 rgb, float exposure) {
    float3 mapped = max(rgb, 0.0) * max(exposure, 1.0);
    return mapped / (1.0 + (max(exposure, 1.0) - 1.0) * max(rgb, 0.0));
}

// Pure Gamma 2.2 transfer function (prevents sRGB piecewise black crush on calibrated displays)
float3 linearToSDRDisplay(float3 rgb) {
    return pow(max(rgb, 0.0), float3(1.0 / 2.2));
}

// Low-end luminance shadow lift with smooth roll-off protection
float3 applyShadowLift(float3 rgb, float amount) {
    float lift = clamp(amount, 0.0, 0.05);
    if (lift <= 0.0) {
        return rgb;
    }
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float blackProtection = smoothstep(0.002, 0.03, luma);
    float shadowWeight = 1.0 - smoothstep(0.14, 0.42, luma);
    float mappedLuma = luma + lift * blackProtection * shadowWeight;
    return rgb * (mappedLuma / max(luma, 1e-6));
}

// BT.709 YUV -> Rec.709 Non-linear RGB (normalized [0, 1])
float3 rgbFromBT709(float y, float2 uv, constant ToneMapUniforms &uniforms) {
    float Y_norm, Cb_norm, Cr_norm;
    if (uniforms.bitDepth == 8) {
        if (uniforms.isFullRange == 1) {
            Y_norm  = y;
            Cb_norm = uv.x - (128.0 / 255.0);
            Cr_norm = uv.y - (128.0 / 255.0);
        } else {
            Y_norm  = (y - (16.0 / 255.0)) / (219.0 / 255.0);
            Cb_norm = (uv.x - (128.0 / 255.0)) / (224.0 / 255.0);
            Cr_norm = (uv.y - (128.0 / 255.0)) / (224.0 / 255.0);
        }
    } else {
        // 10-bit MSB normalized inputs in .r16Unorm / .rg16Unorm
        if (uniforms.isFullRange == 1) {
            Y_norm  = y;
            Cb_norm = uv.x - (32768.0 / 65535.0);
            Cr_norm = uv.y - (32768.0 / 65535.0);
        } else {
            // Video range: Y in [64, 940]/1023, UV in [64, 960]/1023
            Y_norm  = (y - (4096.0 / 65535.0)) / (56064.0 / 65535.0);
            Cb_norm = (uv.x - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
            Cr_norm = (uv.y - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
        }
    }

    float3 rgb = float3(
        Y_norm + 1.5748 * Cr_norm,
        Y_norm - 0.1873 * Cb_norm - 0.4681 * Cr_norm,
        Y_norm + 1.8556 * Cb_norm
    );
    return clamp(rgb, 0.0, 1.0);
}

// BT.709 Linear to Display P3 Linear (Column-major in Metal)
// Mathematical row-major transformation:
// ⎡ Rₚ₃ ⎤   ⎡ 0.822462  0.177538  0.000000 ⎤ ⎡ R₇₀₉ ⎤
// ⎢ Gₚ₃ ⎥ = ⎢ 0.033194  0.966806  0.000000 ⎥ ⎢ G₇₀₉ ⎥
// ⎣ Bₚ₃ ⎦   ⎣ 0.017083  0.072397  0.910520 ⎦ ⎣ B₇₀₉ ⎦
//
// In Metal column-major float3x3(col0, col1, col2):
// col0 = coefficients of R₇₀₉ = (0.822462, 0.033194, 0.017083)
// col1 = coefficients of G₇₀₉ = (0.177538, 0.966806, 0.072397)
// col2 = coefficients of B₇₀₉ = (0.000000, 0.000000, 0.910520)
float3 bt709_to_display_p3(float3 c) {
    float3x3 m = float3x3(
        float3(0.822462, 0.033194, 0.017083), // Column 0 (R₇₀₉)
        float3(0.177538, 0.966806, 0.072397), // Column 1 (G₇₀₉)
        float3(0.000000, 0.000000, 0.910520)  // Column 2 (B₇₀₉)
    );
    return max(m * c, 0.0);
}

// Inverse BT.709 OETF (Rec.709 non-linear to Linear)
float3 bt709ToLinear(float3 nonLinear) {
    return select(
        nonLinear / 4.5,
        pow((nonLinear + 0.099) / 1.099, 1.0 / 0.45),
        nonLinear >= 0.081
    );
}

// Helper to sample and tone map a single texture coordinate
float3 sampleAndToneMap(
    float2 coords,
    texture2d<float, access::sample> texY,
    texture2d<float, access::sample> texUV,
    sampler s,
    constant ToneMapUniforms &uniforms
) {
    float y = texY.sample(s, coords).r;
    float2 uv = texUV.sample(s, coords).rg;

    // Check if SDR Rec.709 mode (transferFunction == 2, or colorPrimaries == 1)
    if (uniforms.transferFunction == 2 || uniforms.colorPrimaries == 1) {
        float3 nonLinearBT709 = rgbFromBT709(y, uv, uniforms);
        float3 linearBT709 = bt709ToLinear(nonLinearBT709);
        float3 p3Linear = bt709_to_display_p3(linearBT709);
        p3Linear = applyOutputExposure(p3Linear, uniforms.outputExposure);
        float3 displayGamma = linearToSDRDisplay(p3Linear);
        if (uniforms.outputShadowLift > 0.0) {
            displayGamma = applyShadowLift(displayGamma, uniforms.outputShadowLift);
        }
        return clamp(displayGamma, 0.0, 1.0);
    }

    // HDR branch: determine linear BT.2020 source optical nits
    float3 sourceNits;
    if (uniforms.colorSpaceMode == 2) {
        // Dolby Vision Profile 5 (IPTc2 / ICtCp)
        sourceNits = nitsFromIPT(y, uv, uniforms);
    } else if (uniforms.transferFunction == 1) {
        // HLG (ARIB STD-B67 / ITU-R BT.2100)
        sourceNits = nitsFromHLG(y, uv, uniforms);
    } else {
        // Standard PQ (SMPTE ST 2084) BT.2020
        sourceNits = nitsFromYUV(y, uv, uniforms);
    }

    // Tone mapping to SDR display white: BT.2390, driven by the stream's (or Dolby Vision L1's) peak.
    float sdrWhite = max(uniforms.targetNits, 100.0);
    float3 mapped2020 = mpvBT2390(sourceNits / sdrWhite, uniforms.sourcePeakNits, sdrWhite);

    // A Dolby Vision L2 trim (SMPTE ST 2094-10 slope / offset / power) corrects the base display mapping, so it goes
    // on top of it, never in its place: the base output is taken as the signal of the trim's target display (white =
    // its peak), the SOP curve is applied to its PQ code normalized to that peak, and the result is read back at our
    // white. Neutral trims (1, 0, 1) leave the base curve unchanged. The curve maps the max-RGB intensity, like the
    // base curve, and RGB is scaled by its ratio: per channel, a power or offset would shift hues.
    if (uniforms.hasDoviL2Trim == 1) {
        float3 base = clamp(mapped2020, 0.0, 1.0);
        float baseMax = max(base.r, max(base.g, base.b));
        float trimPeakNits = max(uniforms.doviTrimTargetNits, 1.0);
        float trimPeakPQ = nitsToPQ(float3(trimPeakNits)).x;
        float basePQ = nitsToPQ(float3(baseMax * trimPeakNits)).x / trimPeakPQ;
        float s = max(uniforms.doviTrimSlope, 0.001);
        float o = uniforms.doviTrimOffset;
        float p = max(uniforms.doviTrimPower, 0.001);
        float trimmedPQ = clamp(pow(max(basePQ * s + o, 1e-6), p), 0.0, 1.0);
        float trimmedMax = pqToNits(float3(trimmedPQ * trimPeakPQ)).x / trimPeakNits;
        float3 trimmed = baseMax > 1e-6 ? base * (trimmedMax / baseMax) : float3(trimmedMax);

        if (uniforms.doviTrimSaturation != 0.0) {
            float satScale = max(1.0 + uniforms.doviTrimSaturation, 0.0);
            float luma = dot(trimmed, float3(0.2627, 0.6780, 0.0593));
            trimmed = mix(float3(luma), trimmed, satScale);
        }
        mapped2020 = clamp(trimmed, 0.0, 1.0);
    }

    float3 p3Linear = bt2020_to_display_p3(mapped2020);
    p3Linear = applyOutputExposure(p3Linear, uniforms.outputExposure);
    float3 displayGamma = linearToSDRDisplay(p3Linear);
    if (uniforms.outputShadowLift > 0.0) {
        displayGamma = applyShadowLift(displayGamma, uniforms.outputShadowLift);
    }
    return clamp(displayGamma, 0.0, 1.0);
}

fragment float4 hdrToneMapFragmentShader(
    VertexOutput in [[stage_in]],
    texture2d<float, access::sample> textureY [[texture(0)]],
    texture2d<float, access::sample> textureUV [[texture(1)]],
    constant ToneMapUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Compute reference tone-mapping pipeline exactly once for the center fragment
    float3 center = sampleAndToneMap(in.texCoords, textureY, textureUV, s, uniforms);

    // Contrast Adaptive Sharpening (FidelityFX CAS)
    float strength = clamp(uniforms.outputSharpness, 0.0, 1.0);
    if (strength <= 0.0) {
        return float4(center, 1.0);
    }

    float2 texelSize = float2(1.0 / float(textureY.get_width()), 1.0 / float(textureY.get_height()));

    // Sample neighbors from single-channel Y texture directly (avoiding 5x redundant BT.2390/PQ math)
    float y_c = textureY.sample(s, in.texCoords).r;
    float y_n = textureY.sample(s, in.texCoords + float2(0.0, -texelSize.y)).r;
    float y_s = textureY.sample(s, in.texCoords + float2(0.0,  texelSize.y)).r;
    float y_w = textureY.sample(s, in.texCoords + float2(-texelSize.x, 0.0)).r;
    float y_e = textureY.sample(s, in.texCoords + float2( texelSize.x, 0.0)).r;

    float y_min = min(y_c, min(min(y_n, y_s), min(y_w, y_e)));
    float y_max = max(y_c, max(max(y_n, y_s), max(y_w, y_e)));

    // Headroom prevents ringing/clipping artifacts near highlight peaks or black floor
    float headroom = min(y_min, 1.0 - y_max);
    float amplitude = sqrt(clamp(headroom / max(y_max, 1.0e-4), 0.0, 1.0));
    // FidelityFX CAS peak formulation: weight stays strictly in [-0.2, 0.0], ensuring (1 + 4*weight) >= 0.2
    float peak = -1.0 / mix(8.0, 5.0, strength);
    float weight = amplitude * peak;

    // High-frequency laplacian luma delta
    float laplacianY = (y_n + y_s + y_w + y_e) - 4.0 * y_c;
    // Scale delta back to display dynamic range and apply contrast enhancement to RGB
    float filterScale = weight / (1.0 + 4.0 * abs(weight));
    float3 sharpened = center + filterScale * laplacianY;

    return float4(clamp(sharpened, 0.0, 1.0), 1.0);
}
