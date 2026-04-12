/// Slug preprocessing: build storage-buffer-ready curve + band data from a GlyphOutline.
///
/// Storage buffer layout (mirrors glyph.frag expectations):
///
///   curveBuffer (vec4[]):
///     [2*i]   = (p1.x, p1.y, p2.x, p2.y)   -- first two control points
///     [2*i+1] = (p3.x, p3.y, 0, 0)          -- third control point
///
///   bandBuffer (uvec2[]) per glyph, starting at bandBase:
///     [bandBase + 0 .. bandBase + nbH - 1]       : horizontal band entries (count, curveListBase)
///     [bandBase + nbH .. bandBase + nbH + nbV - 1]: vertical band entries
///     [bandBase + nbH + nbV ...]                 : curve index lists for each band (curveDataIndex, 0)
///
module slug.preprocess;

import font.types;
import core.stdc.math : fmin, fmax, floorf, ceilf;
import std.algorithm : sort, map;
import std.array : array;

// Number of horizontal / vertical bands per glyph.
// bandMax.x/y are stored in 8 bits -> max 255 per direction.
enum uint nbH = 16; // horizontal bands (y-based)
enum uint nbV = 16; // vertical bands   (x-based)

/// Raw GPU-ready data for one glyph.
struct SlugGlyphData
{
    uint[] curveBuffer; // flat vec4 words (4 floats = 1 vec4; each curve = 2 vec4s)
    uint[] bandBuffer; // flat uvec2 words (2 uints per entry)

    uint bandBase; // index of first band entry in bandBuffer (always 0 for per-glyph)

    // Vertex attributes
    float[4] bnd; // (bandScaleX, bandScaleY, bandOffsetX, bandOffsetY)
    uint bandMaxPacked; // (nbV-1) | ((nbH-1) << 8)  fits in bandMax fields

    // Used to build GlyphVertex
    float xMin, yMin, xMax, yMax; // em-space bbox
    float advanceX;
}

/// Accumulated GPU buffers for all glyphs in a render batch.
struct SlugBatch
{
    float[] curveData; // vec4 elements (4 floats each)
    uint[] bandData; // uvec2 elements (2 uints each)

    /// Per-glyph band base (index into bandData[], not bytes)
    uint[] glyphBandBases;

    struct GlyphMeta
    {
        float[4] bnd;
        uint bandMaxPacked;
        float xMin, yMin, xMax, yMax;
        float advanceX;
    }
    GlyphMeta[] metas;
}

private alias CurveRef = uint; // index into curves[] array

/// Determine which horizontal bands [0, nbH) a curve intersects.
private void hBandsOf(ref const QuadCurve c, float yMin, float bandH,
                       out uint lo, out uint hi)
{
    float cylo, cyhi;
    c.yRange(cylo, cyhi);
    int ilo = cast(int)floorf((cylo - yMin) / bandH);
    int ihi = cast(int)floorf((cyhi - yMin) / bandH);
    lo = cast(uint)(ilo < 0 ? 0 : ilo);
    hi = cast(uint)(ihi >= cast(int)nbH ? nbH - 1 : ihi);
}

/// Determine which vertical bands [0, nbV) a curve intersects.
private void vBandsOf(ref const QuadCurve c, float xMin, float bandW,
                       out uint lo, out uint hi)
{
    float cxlo, cxhi;
    c.xRange(cxlo, cxhi);
    int ilo = cast(int)floorf((cxlo - xMin) / bandW);
    int ihi = cast(int)floorf((cxhi - xMin) / bandW);
    lo = cast(uint)(ilo < 0 ? 0 : ilo);
    hi = cast(uint)(ihi >= cast(int)nbV ? nbV - 1 : ihi);
}

/// Process one GlyphOutline into GPU-ready buffers.
SlugGlyphData processGlyph(ref const GlyphOutline outline)
{
    SlugGlyphData result;

    result.xMin = outline.bbox.xMin;
    result.yMin = outline.bbox.yMin;
    result.xMax = outline.bbox.xMax;
    result.yMax = outline.bbox.yMax;
    result.advanceX = outline.advanceX;

    immutable float bboxW = result.xMax - result.xMin;
    immutable float bboxH = result.yMax - result.yMin;
    immutable float bandW = bboxW / nbV;
    immutable float bandH = bboxH / nbH;

    // Band transform: bandIndex = clamp(renderCoord * bnd.xy + bnd.zw, 0, bandMax)
    result.bnd[0] = bboxW > 0 ? cast(float)nbV / bboxW : 0; // scale x -> vertical band
    result.bnd[1] = bboxH > 0 ? cast(float)nbH / bboxH : 0; // scale y -> horizontal band
    result.bnd[2] = -result.xMin * result.bnd[0];
    result.bnd[3] = -result.yMin * result.bnd[1];

    result.bandMaxPacked = (nbV - 1) | ((nbH - 1) << 8);

    // Build per-band curve reference lists
    uint[][nbH] hBands;
    uint[][nbV] vBands;

    foreach (size_t ci_, ref const QuadCurve c; outline.curves)
    {
        uint ci = cast(uint)ci_;
        if (bandH > 0)
        {
            uint hlo, hhi;
            hBandsOf(c, result.yMin, bandH, hlo, hhi);
            foreach (b; hlo .. hhi + 1)
                hBands[b] ~= ci;
        }
        if (bandW > 0)
        {
            uint vlo, vhi;
            vBandsOf(c, result.xMin, bandW, vlo, vhi);
            foreach (b; vlo .. vhi + 1)
                vBands[b] ~= ci;
        }
    }

    // Sort horizontal bands by descending maxX of curve (early-exit optimisation)
    foreach (b; 0 .. nbH)
    {
        hBands[b].sort!((a, b_) =>
            outline.curves[a].maxX > outline.curves[b_].maxX);
    }
    // Sort vertical bands by descending maxY
    foreach (b; 0 .. nbV)
    {
        vBands[b].sort!((a, b_) =>
            outline.curves[a].maxY > outline.curves[b_].maxY);
    }

    // Build curve buffer (2 vec4s per curve)
    result.curveBuffer.length = outline.curves.length * 8; // 2 vec4s * 4 floats each
    foreach (size_t ci_, ref const QuadCurve c; outline.curves)
    {
        uint ci = cast(uint)ci_;
        uint base = ci * 8;
        result.curveBuffer[base + 0] = *cast(uint*)&c.p0.x;
        result.curveBuffer[base + 1] = *cast(uint*)&c.p0.y;
        result.curveBuffer[base + 2] = *cast(uint*)&c.p1.x;
        result.curveBuffer[base + 3] = *cast(uint*)&c.p1.y;
        float zero = 0;
        result.curveBuffer[base + 4] = *cast(uint*)&c.p2.x;
        result.curveBuffer[base + 5] = *cast(uint*)&c.p2.y;
        result.curveBuffer[base + 6] = *cast(uint*)&zero;
        result.curveBuffer[base + 7] = *cast(uint*)&zero;
    }

    // Build band buffer
    //   Slot layout (each slot = uvec2 = 2 uints):
    //   [0 .. nbH-1]          : horizontal band entries (count, curveListBase)
    //   [nbH .. nbH+nbV-1]   : vertical band entries
    //   [nbH+nbV ..]         : curve index lists for each band
    uint[] bb; // band buffer (pairs of uints, stored flat)
    bb.length = (nbH + nbV) * 2; // reserve header; will append curve lists below

    uint appendOffset = nbH + nbV; // first free uvec2 slot for curve lists

    // Write horizontal band entries + append curve lists
    foreach (uint b; 0 .. nbH)
    {
        uint slot = b * 2;
        uint count = cast(uint)hBands[b].length;
        uint listBase = appendOffset;

        bb[slot] = count;
        bb[slot + 1] = listBase;

        // Append curve index entries (curveDataIndex = ci * 2)
        foreach (ci; hBands[b])
        {
            bb ~= [ci * 2, 0u];
        }
        appendOffset += count;
    }

    // Write vertical band entries + append curve lists
    foreach (uint b; 0 .. nbV)
    {
        uint slot = (nbH + b) * 2;
        uint count = cast(uint)vBands[b].length;
        uint listBase = appendOffset;

        bb[slot] = count;
        bb[slot + 1] = listBase;

        foreach (ci; vBands[b])
        {
            bb ~= [ci * 2, 0u];
        }
        appendOffset += count;
    }

    result.bandBuffer = bb;
    result.bandBase = 0; // per-glyph buffer, base is always 0

    return result;
}

/// Accumulate multiple glyphs into shared GPU buffers.
struct BatchBuilder
{
    float[] curveData; // vec4 flat (4 floats per slot)
    uint[] bandData; // uvec2 flat (2 uints per slot)

    SlugBatch.GlyphMeta[] metas;

    /// Add one glyph, returns the bandBase (in uvec2 slots) for that glyph.
    uint addGlyph(ref const GlyphOutline outline)
    {
        SlugGlyphData g = processGlyph(outline);

        // Curve data offset (in curveData[] slots = vec4 units)
        // Each curve occupies 2 vec4 slots = 8 floats
        // The curveDataIndex stored in bandBuffer is local (0-based).
        // When merging into a batch, we shift all curve indices by curveBase.
        uint curveBase = cast(uint)(curveData.length / 4); // in vec4 units

        // Append curve data (already in float32 as uint bit patterns)
        foreach (w; g.curveBuffer)
            curveData ~= *cast(float*)&w;

        // Shift curve indices in the band buffer's curve lists
        uint bandBase = cast(uint)(bandData.length / 2); // in uvec2 units

        // Copy band buffer, offsetting:
        //  - band entry's curveListBase by bandBase to make it absolute
        //  - curve index entries: add curveBase to each curveDataIndex
        uint nHeaderSlots = nbH + nbV; // header uvec2 entries (before curve lists)
        // First pass: headers (entries 0..nHeaderSlots-1)
        for (uint i = 0; i < nHeaderSlots * 2; i += 2)
        {
            uint count = g.bandBuffer[i];
            uint listBase = g.bandBuffer[i + 1] + bandBase; // absolute offset
            bandData ~= [count, listBase];
        }
        // Second pass: curve index lists (entries nHeaderSlots..)
        for (uint i = nHeaderSlots * 2; i < g.bandBuffer.length; i += 2)
        {
            uint curveIdx = g.bandBuffer[i] + curveBase; // shift by curve base
            bandData ~= [curveIdx, 0u];
        }

        SlugBatch.GlyphMeta m;
        m.bnd = g.bnd;
        m.bandMaxPacked = g.bandMaxPacked;
        m.xMin = g.xMin; m.yMin = g.yMin;
        m.xMax = g.xMax; m.yMax = g.yMax;
        m.advanceX = g.advanceX;
        metas ~= m;

        return bandBase;
    }
}
