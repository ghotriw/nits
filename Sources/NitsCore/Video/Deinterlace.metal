#include <metal_stdlib>
using namespace metal;

/// Motion-adaptive deinterlacing of one plane (luma or interleaved CbCr) of an interlaced frame, keeping one field.
///
/// Lines of the kept field pass through. Each line of the other field is woven in as it is where it fits
/// between its vertical neighbours (static content keeps full vertical resolution) and replaced by an
/// edge-directed interpolation of the kept field where it doesn't (combing from motion between the fields).
/// With the previous frame at hand, a line that looks combed but hasn't changed since that frame (fine static
/// detail such as thin horizontal lines) is woven too, so it doesn't flicker between the two fields' frames.
/// Uses only the current and the previous frame, so it adds no latency.
struct DeinterlaceParams {
    /// Row parity of the kept field: 0 keeps the top field (even rows), 1 the bottom one.
    uint keptParity;
    /// How far (normalized) a woven sample may lie outside its neighbours' range before it counts as combing.
    float combThreshold;
    /// Whether `previous` holds the preceding frame; otherwise every combed sample is interpolated.
    uint hasPrevious;
    /// How far (normalized) a sample may differ from the previous frame and still count as static.
    float motionThreshold;
    /// Whether to count zipped samples into `zippedSamples`: luma only, the decision reads nothing else.
    uint countsZips;
};

static float4 readClamped(texture2d<float, access::read> plane, int x, uint y) {
    int maxX = int(plane.get_width()) - 1;
    return plane.read(uint2(uint(clamp(x, 0, maxX)), y));
}

/// Whether `value` lies outside the range of `a` and `b` by more than `threshold`, in luma or either chroma channel.
static bool outsideRange(float4 value, float4 a, float4 b, float threshold) {
    bool2 outside = (value.rg < min(a, b).rg - threshold) || (value.rg > max(a, b).rg + threshold);
    return outside.x || outside.y;
}

/// Sum of absolute differences over a 3-sample window between the row above (shifted by +d) and the row
/// below (shifted by -d): low along an edge running in that direction.
static float directionCost(texture2d<float, access::read> plane, int x, uint up, uint down, int d) {
    float cost = 0;
    for (int k = -1; k <= 1; k++) {
        float4 delta = abs(readClamped(plane, x + d + k, up) - readClamped(plane, x - d + k, down));
        cost += delta.r + delta.g;
    }
    return cost;
}

kernel void deinterlacePlane(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    texture2d<float, access::read> previous [[texture(2)]],
    constant DeinterlaceParams &params [[buffer(0)]],
    device atomic_uint *zippedSamples [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = source.get_width();
    uint height = source.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 woven = source.read(gid);
    // Kept-field rows, and the first and last rows (one neighbour missing), pass through.
    if ((gid.y & 1u) == params.keptParity || gid.y == 0 || gid.y + 1 >= height) {
        destination.write(woven, gid);
        return;
    }

    uint up = gid.y - 1;
    uint down = gid.y + 1;
    int x = int(gid.x);

    // Combing: the woven sample falls outside the range of its vertical neighbours by more than the threshold.
    float4 above = source.read(uint2(gid.x, up));
    float4 below = source.read(uint2(gid.x, down));
    float4 low = min(above, below) - params.combThreshold;
    float4 high = max(above, below) + params.combThreshold;
    bool2 outside = (woven.rg < low.rg) || (woven.rg > high.rg);
    bool combed = outside.x || outside.y;

    // Static since the previous frame, in this line (the other field) and the kept field's lines around it:
    // the sample is detail, not motion between the fields.
    if (combed && params.hasPrevious != 0) {
        float4 change = max(
            abs(woven - previous.read(gid)),
            max(abs(above - previous.read(uint2(gid.x, up))), abs(below - previous.read(uint2(gid.x, down)))));
        combed = max(change.r, change.g) > params.motionThreshold;
    }
    if (!combed) {
        destination.write(woven, gid);
        return;
    }
    // Count combing that zips, rows alternating over three lines, between the fields (counter 0) and, as the
    // baseline that texture and noise produce anyway, within this line's own field (counter 1). Fine moving detail
    // in progressive video (a thin line, a text stroke) stands out on a single row only.
    if (params.countsZips != 0 && gid.y >= 4 && gid.y + 2 < height) {
        float4 twoAbove = source.read(uint2(gid.x, gid.y - 2));
        // This line already sticks out of its neighbours; it zips when the line above sticks out of its own.
        if (outsideRange(above, twoAbove, woven, params.combThreshold)) {
            atomic_fetch_add_explicit(&zippedSamples[0], 1u, memory_order_relaxed);
        }
        float4 twoBelow = source.read(uint2(gid.x, down + 1));
        float4 fourAbove = source.read(uint2(gid.x, gid.y - 4));
        if (outsideRange(woven, twoAbove, twoBelow, params.combThreshold)
            && outsideRange(twoAbove, fourAbove, woven, params.combThreshold)) {
            atomic_fetch_add_explicit(&zippedSamples[1], 1u, memory_order_relaxed);
        }
    }

    // Edge-directed interpolation from the kept field: pick the direction with the closest match.
    int bestDirection = 0;
    float bestCost = directionCost(source, x, up, down, 0);
    for (int d = -1; d <= 1; d += 2) {
        float cost = directionCost(source, x, up, down, d);
        if (cost < bestCost) {
            bestCost = cost;
            bestDirection = d;
        }
    }
    float4 interpolated =
        0.5 * (readClamped(source, x + bestDirection, up) + readClamped(source, x - bestDirection, down));
    destination.write(interpolated, gid);
}
