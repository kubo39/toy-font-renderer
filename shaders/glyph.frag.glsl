#version 450
// Slug Reference Fragment Shader - translated from HLSL to GLSL (storage buffer version)
// MIT OR Apache-2.0, Copyright 2017, by Eric Lengyel.
//
// Changes from HLSL original:
//   - Texture2D curveTexture / bandTexture replaced with storage buffers
//   - CalcBandLoc / kLogBandTextureWidth removed (no 2D texture wrapping needed)
//   - saturate() -> clamp(x, 0.0, 1.0)
//   - frac() -> fract()
//   - asuint() -> floatBitsToUint()

// Curve data buffer: each curve i occupies entries [2i] and [2i+1]
//   curveData[2i]   = (p1.x, p1.y, p2.x, p2.y)
//   curveData[2i+1] = (p3.x, p3.y, 0, 0)
layout(std430, set = 0, binding = 1) readonly buffer CurveBuffer {
    vec4 curveData[];
};

// Band data buffer: uvec2 per entry
//   Band entry    : (count, curveIndexListBase)
//   Curve idx entry: (curveDataIndex, 0)  -- curveDataIndex is index into curveData[]
layout(std430, set = 0, binding = 2) readonly buffer BandBuffer {
    uvec2 bandData[];
};

layout(location = 0) in  vec4       v_color;
layout(location = 1) in  vec2       v_texcoord;
layout(location = 2) in  flat vec4  v_banding;
layout(location = 3) in  flat ivec4 v_glyph;

layout(location = 0) out vec4 outColor;

// ---------------------------------------------------------------------------
// Root eligibility code for a sample-relative quadratic Bezier curve
// ---------------------------------------------------------------------------
uint CalcRootCode(float y1, float y2, float y3) {
    uint i1 = floatBitsToUint(y1) >> 31u;
    uint i2 = floatBitsToUint(y2) >> 30u;
    uint i3 = floatBitsToUint(y3) >> 29u;

    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return (0x2E74u >> shift) & 0x0101u;
}

// ---------------------------------------------------------------------------
// Solve for x where the quadratic Bezier crosses y=0 (horizontal ray)
// ---------------------------------------------------------------------------
vec2 SolveHorizPoly(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.y;
    float rb = 0.5 / b.y;

    float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0 / 65536.0) { t1 = p12.y * rb; t2 = p12.y * rb; }

    return vec2((a.x * t1 - b.x * 2.0) * t1 + p12.x,
                (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

// ---------------------------------------------------------------------------
// Solve for y where the quadratic Bezier crosses x=0 (vertical ray)
// ---------------------------------------------------------------------------
vec2 SolveVertPoly(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.x;
    float rb = 0.5 / b.x;

    float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0) { t1 = p12.x * rb; t2 = p12.x * rb; }

    return vec2((a.y * t1 - b.y * 2.0) * t1 + p12.y,
                (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

// ---------------------------------------------------------------------------
// Combine horizontal and vertical coverage
// ---------------------------------------------------------------------------
float CalcCoverage(float xcov, float ycov, float xwgt, float ywgt, int flags) {
    float coverage = max(
        abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
        min(abs(xcov), abs(ycov))
    );

#ifdef SLUG_EVENODD
    if ((flags & 0x1000) == 0) {
        coverage = clamp(coverage, 0.0, 1.0);
    } else {
        coverage = 1.0 - abs(1.0 - fract(coverage * 0.5) * 2.0);
    }
#else
    coverage = clamp(coverage, 0.0, 1.0);
#endif

#ifdef SLUG_WEIGHT
    coverage = sqrt(coverage);
#endif

    return coverage;
}

// ---------------------------------------------------------------------------
// Main rendering function
// ---------------------------------------------------------------------------
void main() {
    vec2  renderCoord   = v_texcoord;
    vec4  bandTransform = v_banding;
    ivec4 glyphData     = v_glyph;

    // Reconstruct flat band buffer offset from the two 16-bit halves
    uint bandBase = uint(glyphData.x) | (uint(glyphData.y) << 16u);

    // Pixel size in em units (for coverage weighting)
    vec2 emsPerPixel = fwidth(renderCoord);
    vec2 pixelsPerEm = 1.0 / emsPerPixel;

    ivec2 bandMax   = ivec2(glyphData.z & 0xFF, (glyphData.z >> 8) & 0xFF);
    ivec2 bandIndex = clamp(
        ivec2(renderCoord * bandTransform.xy + bandTransform.zw),
        ivec2(0), bandMax
    );

    // -----------------------------------------------------------------------
    // Horizontal band: curves sorted by descending max-x
    // -----------------------------------------------------------------------
    float xcov = 0.0, xwgt = 0.0;
    {
        uvec2 hband     = bandData[bandBase + uint(bandIndex.y)];
        uint  hCount    = hband.x;
        uint  hListBase = hband.y;

        for (uint ci = 0u; ci < hCount; ci++) {
            uint curveIdx = bandData[hListBase + ci].x;  // index into curveData[]

            vec4 p12 = curveData[curveIdx]      - vec4(renderCoord, renderCoord);
            vec2 p3  = curveData[curveIdx + 1u].xy - renderCoord;

            // Early exit: curves sorted by descending max-x
            if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5) break;

            uint code = CalcRootCode(p12.y, p12.w, p3.y);
            if (code != 0u) {
                vec2 r = SolveHorizPoly(p12, p3) * pixelsPerEm.x;
                if ((code & 1u) != 0u) {
                    xcov += clamp(r.x + 0.5, 0.0, 1.0);
                    xwgt  = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
                }
                if (code > 1u) {
                    xcov -= clamp(r.y + 0.5, 0.0, 1.0);
                    xwgt  = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Vertical band: curves sorted by descending max-y
    // -----------------------------------------------------------------------
    float ycov = 0.0, ywgt = 0.0;
    {
        // Vertical bands start after all horizontal bands: offset = bandMax.y + 1
        uvec2 vband     = bandData[bandBase + uint(bandMax.y) + 1u + uint(bandIndex.x)];
        uint  vCount    = vband.x;
        uint  vListBase = vband.y;

        for (uint ci = 0u; ci < vCount; ci++) {
            uint curveIdx = bandData[vListBase + ci].x;

            vec4 p12 = curveData[curveIdx]      - vec4(renderCoord, renderCoord);
            vec2 p3  = curveData[curveIdx + 1u].xy - renderCoord;

            // Early exit: curves sorted by descending max-y
            if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5) break;

            uint code = CalcRootCode(p12.x, p12.z, p3.x);
            if (code != 0u) {
                vec2 r = SolveVertPoly(p12, p3) * pixelsPerEm.y;
                if ((code & 1u) != 0u) {
                    ycov -= clamp(r.x + 0.5, 0.0, 1.0);
                    ywgt  = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
                }
                if (code > 1u) {
                    ycov += clamp(r.y + 0.5, 0.0, 1.0);
                    ywgt  = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
                }
            }
        }
    }

    float coverage = CalcCoverage(xcov, ycov, xwgt, ywgt, glyphData.w);
    outColor = v_color * coverage;
}
