module font.types;

/// A 2D point in em-space (font units)
struct Point
{
    float x, y;
}

/// Axis-aligned bounding box in em-space
struct BBox
{
    float xMin, yMin, xMax, yMax;

    float width() const { return xMax - xMin; }
    float height() const { return yMax - yMin; }
}

/// A single quadratic Bezier curve: start p0, control p1, end p2
struct QuadCurve
{
    Point p0, p1, p2;

    float maxX() const { return max3(p0.x, p1.x, p2.x); }
    float maxY() const { return max3(p0.y, p1.y, p2.y); }
    float minX() const { return min3(p0.x, p1.x, p2.x); }
    float minY() const { return min3(p0.y, p1.y, p2.y); }

    // Tight y-range considering the curve's extremum
    void yRange(out float lo, out float hi) const
    {
        lo = fmin(p0.y, p2.y);
        hi = fmax(p0.y, p2.y);
        float denom = p0.y - 2.0f * p1.y + p2.y;
        if (fabs(denom) > 1e-6f)
        {
            float t = (p0.y - p1.y) / denom;
            if (t > 0.0f && t < 1.0f)
            {
                float mt = 1.0f - t;
                float ey = mt * mt * p0.y + 2.0f * t * mt * p1.y + t * t * p2.y;
                lo = fmin(lo, ey);
                hi = fmax(hi, ey);
            }
        }
    }

    // Tight x-range considering the curve's extremum
    void xRange(out float lo, out float hi) const
    {
        lo = fmin(p0.x, p2.x);
        hi = fmax(p0.x, p2.x);
        float denom = p0.x - 2.0f * p1.x + p2.x;
        if (fabs(denom) > 1e-6f)
        {
            float t = (p0.x - p1.x) / denom;
            if (t > 0.0f && t < 1.0f)
            {
                float mt = 1.0f - t;
                float ex = mt * mt * p0.x + 2.0f * t * mt * p1.x + t * t * p2.x;
                lo = fmin(lo, ex);
                hi = fmax(hi, ex);
            }
        }
    }
}

/// Extracted outline for one glyph (em-space, font units, scale=1.0)
struct GlyphOutline
{
    QuadCurve[] curves;
    BBox        bbox;
    float       advanceX; // horizontal advance in font units
}

private:
import core.stdc.math : fmin, fmax, fabs;

float max3(float a, float b, float c) { return fmax(fmax(a, b), c); }
float min3(float a, float b, float c) { return fmin(fmin(a, b), c); }
