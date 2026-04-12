/// HarfBuzz -> GlyphOutline adapter
module font.adapter;

import font.types;
import font.hb;
import core.stdc.math : fmin, fmax;

private struct Ctx
{
    QuadCurve[] curves;
    float lastX = 0, lastY = 0;
    float moveX = 0, moveY = 0;
}

// HarfBuzz returns Y-up coordinates (font standard), but the rest of the
// pipeline (Slug preprocessing, shaders, screen layout) expects Y-down.
// Negate Y in every callback to convert.

private void cbMoveTo(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*,
                       float toX, float toY, void*)
{
    auto ctx = cast(Ctx*)drawData;
    toY = -toY;
    if (ctx.lastX != ctx.moveX || ctx.lastY != ctx.moveY)
    {
        QuadCurve c;
        c.p0 = Point(ctx.lastX, ctx.lastY);
        c.p1 = Point((ctx.lastX + ctx.moveX) * 0.5f, (ctx.lastY + ctx.moveY) * 0.5f);
        c.p2 = Point(ctx.moveX, ctx.moveY);
        ctx.curves ~= c;
    }
    ctx.moveX = toX; ctx.moveY = toY;
    ctx.lastX = toX; ctx.lastY = toY;
}

private void cbLineTo(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*,
                       float toX, float toY, void*)
{
    auto ctx = cast(Ctx*)drawData;
    toY = -toY;
    QuadCurve c;
    c.p0 = Point(ctx.lastX, ctx.lastY);
    c.p1 = Point((ctx.lastX + toX) * 0.5f, (ctx.lastY + toY) * 0.5f);
    c.p2 = Point(toX, toY);
    ctx.curves ~= c;
    ctx.lastX = toX; ctx.lastY = toY;
}

private void cbQuadraticTo(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*,
                            float cx, float cy, float toX, float toY, void*)
{
    auto ctx = cast(Ctx*)drawData;
    cy = -cy; toY = -toY;
    QuadCurve c;
    c.p0 = Point(ctx.lastX, ctx.lastY);
    c.p1 = Point(cx, cy);
    c.p2 = Point(toX, toY);
    ctx.curves ~= c;
    ctx.lastX = toX; ctx.lastY = toY;
}

// Cubic → approximate via two quadratics (de Casteljau split at t=0.5)
private void cbCubicTo(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*,
                        float c1x, float c1y, float c2x, float c2y,
                        float toX, float toY, void*)
{
    auto ctx = cast(Ctx*)drawData;
    c1y = -c1y; c2y = -c2y; toY = -toY;
    float x0 = ctx.lastX, y0 = ctx.lastY;

    float mx = (x0 + 3*c1x + 3*c2x + toX) * 0.125f;
    float my = (y0 + 3*c1y + 3*c2y + toY) * 0.125f;
    float mc1x = (x0 + c1x) * 0.5f, mc1y = (y0 + c1y) * 0.5f;
    float mc2x = (c1x + c2x) * 0.5f, mc2y = (c1y + c2y) * 0.5f;
    float mc3x = (c2x + toX) * 0.5f, mc3y = (c2y + toY) * 0.5f;
    float q1cx = (mc1x + mc2x) * 0.5f, q1cy = (mc1y + mc2y) * 0.5f;
    float q2cx = (mc2x + mc3x) * 0.5f, q2cy = (mc2y + mc3y) * 0.5f;

    QuadCurve c1, c2;
    c1.p0 = Point(x0, y0); c1.p1 = Point(q1cx, q1cy); c1.p2 = Point(mx, my);
    c2.p0 = Point(mx, my); c2.p1 = Point(q2cx, q2cy); c2.p2 = Point(toX, toY);
    ctx.curves ~= c1;
    ctx.curves ~= c2;
    ctx.lastX = toX; ctx.lastY = toY;
}

private void cbClosePath(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*,
                          void*)
{
    auto ctx = cast(Ctx*)drawData;
    if (ctx.lastX != ctx.moveX || ctx.lastY != ctx.moveY)
    {
        QuadCurve c;
        c.p0 = Point(ctx.lastX, ctx.lastY);
        c.p1 = Point((ctx.lastX + ctx.moveX) * 0.5f, (ctx.lastY + ctx.moveY) * 0.5f);
        c.p2 = Point(ctx.moveX, ctx.moveY);
        ctx.curves ~= c;
    }
    ctx.lastX = ctx.moveX; ctx.lastY = ctx.moveY;
}

// Draw funcs singleton (created once, reused)
private __gshared hb_draw_funcs_t* gDrawFuncs;

private hb_draw_funcs_t* getDrawFuncs()
{
    if (gDrawFuncs is null)
    {
        gDrawFuncs = hb_draw_funcs_create();
        hb_draw_funcs_set_move_to_func(gDrawFuncs, &cbMoveTo, null, null);
        hb_draw_funcs_set_line_to_func(gDrawFuncs, &cbLineTo, null, null);
        hb_draw_funcs_set_quadratic_to_func(gDrawFuncs, &cbQuadraticTo, null, null);
        hb_draw_funcs_set_cubic_to_func(gDrawFuncs, &cbCubicTo, null, null);
        hb_draw_funcs_set_close_path_func(gDrawFuncs, &cbClosePath, null, null);
    }
    return gDrawFuncs;
}

/// Extract glyph outline from HarfBuzz given a glyph ID.
GlyphOutline extractOutline(hb_font_t* font, hb_codepoint_t glyphId, float upem)
{
    Ctx ctx;
    hb_font_draw_glyph(font, glyphId, getDrawFuncs(), &ctx);

    GlyphOutline result;
    result.curves = ctx.curves;
    result.advanceX = cast(float)hb_font_get_glyph_h_advance(font, glyphId);

    if (result.curves.length > 0)
    {
        float xlo = float.infinity, ylo = float.infinity;
        float xhi = -float.infinity, yhi = -float.infinity;
        foreach (ref c; result.curves)
        {
            xlo = fmin(xlo, c.minX); xhi = fmax(xhi, c.maxX);
            ylo = fmin(ylo, c.minY); yhi = fmax(yhi, c.maxY);
        }
        result.bbox = BBox(xlo, ylo, xhi, yhi);
    }
    else
    {
        result.bbox = BBox(0, 0, result.advanceX, upem);
    }

    return result;
}

/// Extract glyph outline given a font + codepoint.
GlyphOutline extractGlyphOutline(hb_font_t* font, dchar codepoint, float upem)
{
    hb_codepoint_t glyphId;
    if (!hb_font_get_nominal_glyph(font, cast(hb_codepoint_t)codepoint, &glyphId))
        glyphId = 0; // .notdef

    return extractOutline(font, glyphId, upem);
}
