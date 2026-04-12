#version 450
// Slug Reference Vertex Shader - translated from HLSL to GLSL
// MIT OR Apache-2.0, Copyright 2017, by Eric Lengyel.

layout(set = 0, binding = 0) uniform ParamBlock {
    vec4 slug_matrix[4];   // rows of the MVP matrix
    vec4 slug_viewport;    // (width, height, 0, 0) in pixels
} params;

layout(location = 0) in vec4 pos;  // (obj-space x, y, normal x, normal y)
layout(location = 1) in vec4 tex;  // (em x, em y, bandBase packed, bandMax packed)
layout(location = 2) in vec4 jac;  // 2x2 inverse Jacobian (j00, j01, j10, j11)
layout(location = 3) in vec4 bnd;  // (band scale x, band scale y, band offset x, band offset y)
layout(location = 4) in vec4 col;  // (R, G, B, A)

layout(location = 0) out vec4      v_color;
layout(location = 1) out vec2      v_texcoord;
layout(location = 2) out flat vec4 v_banding;
layout(location = 3) out flat ivec4 v_glyph;

void main() {
    // SlugUnpack: decode band location and band max from tex.zw
    uvec2 g = floatBitsToUint(tex.zw);
    v_glyph = ivec4(
        int(g.x & 0xFFFFu),
        int(g.x >> 16u),
        int(g.y & 0xFFFFu),
        int(g.y >> 16u)
    );
    v_banding = bnd;
    v_color   = col;

    // SlugDilate: dynamic dilation for correct anti-aliasing under perspective
    vec2 n  = normalize(pos.zw);
    float s = dot(params.slug_matrix[3].xy, pos.xy) + params.slug_matrix[3].w;
    float t = dot(params.slug_matrix[3].xy, n);

    float u = (s * dot(params.slug_matrix[0].xy, n)
             - t * (dot(params.slug_matrix[0].xy, pos.xy) + params.slug_matrix[0].w))
             * params.slug_viewport.x;
    float v = (s * dot(params.slug_matrix[1].xy, n)
             - t * (dot(params.slug_matrix[1].xy, pos.xy) + params.slug_matrix[1].w))
             * params.slug_viewport.y;

    float s2 = s * s;
    float st = s * t;
    float uv = u * u + v * v;
    vec2  d  = pos.zw * (s2 * (st + sqrt(max(uv, 0.0))) / max(uv - st * st, 1e-10));

    vec2 p    = pos.xy + d;
    v_texcoord = vec2(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));

    // Apply MVP to dilated position
    gl_Position = vec4(
        p.x * params.slug_matrix[0].x + p.y * params.slug_matrix[0].y + params.slug_matrix[0].w,
        p.x * params.slug_matrix[1].x + p.y * params.slug_matrix[1].y + params.slug_matrix[1].w,
        p.x * params.slug_matrix[2].x + p.y * params.slug_matrix[2].y + params.slug_matrix[2].w,
        p.x * params.slug_matrix[3].x + p.y * params.slug_matrix[3].y + params.slug_matrix[3].w
    );
}
