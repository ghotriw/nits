/*
 * Rec.2020 -> Display P3 at constant Oklab lightness and hue, reducing chroma only: the gamut step after either tone
 * curve. Clipping each P3 channel instead skews a colour outside P3 towards the channel that survives (a sunset's
 * orange towards yellow).
 *
 * The GPU form of ToneLab's oklab_gamut_fit (research/tone_mappers.py), with its constants: for each P3 channel, the
 * chroma scale at which Oklab (L, s*a, s*b) reaches 1 and 0 is the first crossing of a cubic in s, bracketed by the
 * cubic's critical points and refined by safeguarded Newton; a smooth min across the six keeps the result free of
 * kinks where the limiting channel changes. Colours that fit with a margin pass unchanged; those on the boundary where
 * two channels limit at once lose up to ~7% of chroma. Lightness above white maps to white.
 *
 * Copyright (C) 2026 Andrii Honcharov.
 * Licensed under the MIT License. See LICENSE in the project root.
 *
 * SPDX-License-Identifier: MIT
 */

#include <metal_stdlib>
using namespace metal;

// Oklab (Ottosson 2020) for linear Rec.2020, normalised so D65 white -> LMS (1, 1, 1) (column-major)
constant float3x3 kGamutFitRgb2020ToLms = float3x3(
    float3(0.6167557877, 0.2651330603, 0.1001026312),
    float3(0.3601984026, 0.6358393718, 0.2039065206),
    float3(0.0230458097, 0.0990275679, 0.6959908482)
);

// Oklab LMS -> linear Display P3 (Rec.2020 -> P3 after LMS -> Rec.2020); rows sum to 1, so greys stay grey
constant float3x3 kGamutFitLmsToP3 = float3x3(
    float3(3.1277689575, -1.0910090162, -0.0260108089),
    float3(-2.2571357666, 2.4133317139, -0.5080413225),
    float3(0.1293668089, -0.3223226976, 1.5340521316)
);

// First row of Oklab M2: lightness L from LMS'
constant float3 kGamutFitLightness = float3(0.2104542553, 0.7936177850, -0.0040720468);

constant float kGamutFitEdgeSmoothing = 0.3;  // blend width of the smooth min across channels, in ln(chroma scale)
constant float kGamutFitSearchMax = 8.0;      // chroma scales above this count as "fits with room to spare"
constant int kGamutFitRefineSteps = 8;        // safeguarded Newton iterations inside the monotonic bracket

// Quadratic smooth min of ln a and ln b, never above min(a, b).
static float gamutFitSmoothMin(float a, float b) {
    float la = log(a);
    float lb = log(b);
    float h = max(kGamutFitEdgeSmoothing - abs(la - lb), 0.0) / kGamutFitEdgeSmoothing;
    return exp(min(la, lb) - h * h * kGamutFitEdgeSmoothing / 4.0);
}

// coef = (c0, c1, c2, c3): c3 s^3 + c2 s^2 + c1 s + c0; derivative through df.
static float gamutFitCubic(float4 coef, float s, thread float &df) {
    df = (3.0 * coef.w * s + 2.0 * coef.z) * s + coef.y;
    return ((coef.w * s + coef.z) * s + coef.y) * s + coef.x;
}

// Smallest s in [0, kGamutFitSearchMax] where the cubic reaches 0 from below, or kGamutFitSearchMax if it never does.
static float gamutFitFirstCrossing(float4 coef) {
    float df;
    if (gamutFitCubic(coef, 0.0, df) >= -1e-6) {
        return 0.0;  // already on the boundary: no chroma fits
    }
    float a = 3.0 * coef.w;
    float b = 2.0 * coef.z;
    float c = coef.y;
    float disc = b * b - 4.0 * a * c;
    float t1 = kGamutFitSearchMax;
    float t2 = kGamutFitSearchMax;
    if (disc >= 0.0) {
        float sq = sqrt(disc);
        float q = -0.5 * (b + (b >= 0.0 ? sq : -sq));
        float r1 = abs(a) > 1e-12 ? q / a : -c / (abs(b) > 1e-12 ? b : 1e-12);
        float r2 = abs(q) > 1e-12 ? c / q : kGamutFitSearchMax;
        t1 = (r1 > 0.0 && r1 < kGamutFitSearchMax) ? r1 : kGamutFitSearchMax;
        t2 = (r2 > 0.0 && r2 < kGamutFitSearchMax) ? r2 : kGamutFitSearchMax;
    }
    float edges[3] = { min(t1, t2), max(t1, t2), kGamutFitSearchMax };
    float lo = 0.0;
    float hi = -1.0;
    for (int i = 0; i < 3; ++i) {
        if (gamutFitCubic(coef, edges[i], df) >= 0.0) {
            hi = edges[i];
            break;
        }
        lo = edges[i];
    }
    if (hi < 0.0) {
        return kGamutFitSearchMax;
    }

    float s = 0.5 * (lo + hi);
    for (int step = 0; step < kGamutFitRefineSteps; ++step) {
        float f = gamutFitCubic(coef, s, df);
        if (f < 0.0) {
            lo = s;
        } else {
            hi = s;
        }
        float sNewton = s - f / (abs(df) > 1e-12 ? df : 1e-12);
        s = (sNewton >= lo && sNewton <= hi) ? sNewton : 0.5 * (lo + hi);
    }
    return s;
}

// rgb2020: linear Rec.2020, 1.0 = white. Returns linear Display P3 in [0, 1].
float3 fitToDisplayP3(float3 rgb2020) {
    float3 lmsP = pow(kGamutFitRgb2020ToLms * max(rgb2020, 0.0), float3(1.0 / 3.0));
    float lightness = min(dot(lmsP, kGamutFitLightness), 1.0);
    float3 lmsDir = lmsP - lightness;
    // Each P3 channel along (L + s * d)^3 is a cubic in s.
    float3 c0 = kGamutFitLmsToP3 * float3(lightness * lightness * lightness);
    float3 c1 = kGamutFitLmsToP3 * (3.0 * lightness * lightness * lmsDir);
    float3 c2 = kGamutFitLmsToP3 * (3.0 * lightness * lmsDir * lmsDir);
    float3 c3 = kGamutFitLmsToP3 * (lmsDir * lmsDir * lmsDir);

    // Upper bounds of R, G, B, then lower ones, folded in the model's order.
    float sFit = max(gamutFitFirstCrossing(float4(c0.r - 1.0, c1.r, c2.r, c3.r)), 1e-9);
    sFit = gamutFitSmoothMin(sFit, max(gamutFitFirstCrossing(float4(c0.g - 1.0, c1.g, c2.g, c3.g)), 1e-9));
    sFit = gamutFitSmoothMin(sFit, max(gamutFitFirstCrossing(float4(c0.b - 1.0, c1.b, c2.b, c3.b)), 1e-9));
    sFit = gamutFitSmoothMin(sFit, max(gamutFitFirstCrossing(-float4(c0.r, c1.r, c2.r, c3.r)), 1e-9));
    sFit = gamutFitSmoothMin(sFit, max(gamutFitFirstCrossing(-float4(c0.g, c1.g, c2.g, c3.g)), 1e-9));
    sFit = gamutFitSmoothMin(sFit, max(gamutFitFirstCrossing(-float4(c0.b, c1.b, c2.b, c3.b)), 1e-9));
    float s = min(sFit, 1.0);

    float3 lp = lightness + s * lmsDir;
    return clamp(kGamutFitLmsToP3 * (lp * lp * lp), 0.0, 1.0);
}
