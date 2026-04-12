/// Minimal outline normalization.
/// HarfBuzz draw callbacks return explicit bezier curves, so the main job
/// here is dropping zero-length degenerate curves.
module outline.normalize;

import font.types;
import core.stdc.math : fabsf;

/// Remove degenerate (zero-length) curves from an outline.
void normalize(ref GlyphOutline outline)
{
    QuadCurve[] kept;
    kept.reserve(outline.curves.length);
    foreach (ref c; outline.curves)
    {
        float dx0 = c.p2.x - c.p0.x;
        float dy0 = c.p2.y - c.p0.y;
        if (fabsf(dx0) > 0.01f || fabsf(dy0) > 0.01f)
            kept ~= c;
    }
    outline.curves = kept;
}
