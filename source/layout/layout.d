/// Text layout using HarfBuzz shaping.
module layout.layout;

import font.types : GlyphOutline;
import font.hb;
import slug.preprocess : BatchBuilder;
import raster.gpu : GlyphRenderer;

struct GlyphCache
{
    hb_font_t* font;
    float upem;

    /// HarfBuzz glyph ID -> renderer batch index
    uint[hb_codepoint_t] glyphIndex;

    void init(hb_font_t* hbFont, float unitsPerEm)
    {
        font = hbFont;
        upem = unitsPerEm;
    }

    /// Ensure the glyph for the given glyph ID is loaded into `renderer`.
    uint getOrLoad(ref GlyphRenderer renderer, hb_codepoint_t glyphId)
    {
        if (auto p = glyphId in glyphIndex)
            return *p;

        import font.adapter : extractOutline;
        import outline.normalize : normalize;

        GlyphOutline outline = extractOutline(font, glyphId, upem);
        normalize(outline);

        uint idx = renderer.addGlyph(outline);
        glyphIndex[glyphId] = idx;
        return idx;
    }

    /// Ensure the glyph for a codepoint is loaded (without shaping).
    uint getOrLoadCodepoint(ref GlyphRenderer renderer, dchar cp)
    {
        hb_codepoint_t glyphId;
        if (!hb_font_get_nominal_glyph(font, cast(hb_codepoint_t)cp, &glyphId))
            glyphId = 0;
        return getOrLoad(renderer, glyphId);
    }
}

struct GlyphInstance
{
    uint glyphIdx;
    float x, y; // screen position (baseline origin, y-down)
}

/// Lay out `text` using HarfBuzz shaping, starting at (penX, penY) in screen pixels.
/// penY is the baseline position (y-down screen coordinates).
/// pixelsPerEm determines the physical size.
GlyphInstance[] layoutText(ref GlyphCache cache,
                            ref GlyphRenderer renderer,
                            string text,
                            float penX, float penY,
                            float pixelsPerEm)
{
    if (text.length == 0)
        return null;

    // Create HarfBuzz buffer and shape
    hb_buffer_t* buf = hb_buffer_create();
    scope(exit) hb_buffer_destroy(buf);

    hb_buffer_add_utf8(buf, text.ptr,
                        cast(int)text.length, 0, cast(int)text.length);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(cache.font, buf, null, 0);

    uint glyphCount;
    hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buf, &glyphCount);
    hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buf, &glyphCount);

    GlyphInstance[] result;
    result.reserve(glyphCount);

    float scale = pixelsPerEm / cache.upem;
    float curX = penX;
    float curY = penY;

    foreach (i; 0 .. glyphCount)
    {
        hb_codepoint_t glyphId = infos[i].codepoint;
        uint idx = cache.getOrLoad(renderer, glyphId);

        GlyphInstance gi;
        gi.glyphIdx = idx;
        gi.x = curX + cast(float)positions[i].x_offset * scale;
        gi.y = curY + cast(float)positions[i].y_offset * scale;
        result ~= gi;

        curX += cast(float)positions[i].x_advance * scale;
        curY += cast(float)positions[i].y_advance * scale;
    }
    return result;
}
