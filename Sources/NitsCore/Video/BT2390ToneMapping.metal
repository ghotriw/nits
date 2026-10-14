/*
 * BT.2390 tone mapping for Nits.
 *
 * Derived from mpv's pass_tone_map() (video/out/gpu/video_shaders.c, https://mpv.io):
 * the PQ-space ITU-R BT.2390 EETF spline and the 0.18 / 0.90 / 0.20 desaturation step.
 * Copyright (C) the mpv developers; modifications copyright (C) 2026 Andrii Honcharov.
 *
 * Unlike the rest of Nits (MIT), this file is licensed under the GNU Lesser General Public
 * License as published by the Free Software Foundation; either version 2.1 of the License,
 * or (at your option) any later version. See THIRD_PARTY_NOTICES.md.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU Lesser General Public License for more details.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include <metal_stdlib>
using namespace metal;

// PQ helpers, defined in HDRToneMapping.metal.
float nitsToPQ(float value);
float3 pqToNits(float3 value);

float3 mpvBT2390(float3 color, float sourcePeakNits, float sdrWhiteNits) {
    float sourcePeak = max(sourcePeakNits / sdrWhiteNits, 1.0);
    uint signalIndex = color.g > color.r ? 1 : 0;
    signalIndex = color.b > color[signalIndex] ? 2 : signalIndex;
    float3 signal = min(color, float3(sourcePeak));
    float originalSignal = max(signal[signalIndex], 1e-6);

    float4 signalPQ = float4(signal, sourcePeak) * (sdrWhiteNits / 10000.0);
    signalPQ = pow(max(signalPQ, 0.0), float4(2610.0 / 16384.0));
    signalPQ = (float4(3424.0 / 4096.0) + (2413.0 / 128.0) * signalPQ)
        / (1.0 + (2392.0 / 128.0) * signalPQ);
    signalPQ = pow(signalPQ, float4(2523.0 / 32.0));

    float sourceScale = 1.0 / max(signalPQ.a, 1e-6);
    signalPQ.rgb *= sourceScale;
    float targetPeakPQ = nitsToPQ(sdrWhiteNits) * sourceScale;
    float knee = 1.5 * targetPeakPQ - 0.5;

    float3 t = (signalPQ.rgb - knee) / max(1.0 - knee, 1e-6);
    float3 t2 = t * t;
    float3 t3 = t2 * t;
    float3 spline = (2.0 * t3 - 3.0 * t2 + 1.0) * knee
        + (t3 - 2.0 * t2 + t) * (1.0 - knee)
        + (-2.0 * t3 + 3.0 * t2) * targetPeakPQ;

    float3 mappedPQ = select(spline, signalPQ.rgb, signalPQ.rgb < knee);
    signal = pqToNits(mappedPQ * signalPQ.a) / sdrWhiteNits;

    float mappedMaximum = signal[signalIndex];
    float coefficient = max(mappedMaximum - 0.18, 1e-6) / max(mappedMaximum, 1.0);
    coefficient = 0.90 * pow(coefficient, 0.20);

    float sourceLumaNits = sdrWhiteNits * dot(color, float3(0.2627, 0.6780, 0.0593));
    float brightChromaProtection = max(
        smoothstep(0.35, 0.70, sourceLumaNits / sdrWhiteNits),
        smoothstep(260.0, 520.0, sourceLumaNits)
    );
    coefficient *= mix(1.0, 0.02, brightChromaProtection);

    float3 scaledColor = color * (mappedMaximum / originalSignal);
    return mix(scaledColor, signal, coefficient);
}
