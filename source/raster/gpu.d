/// High-level Vulkan GPU renderer for Slug glyph rendering.
///
/// Owns:
///   - per-frame uniform buffer (ParamBlock)
///   - device-local curve + band storage buffers (rebuilt on font change)
///   - vertex buffer (rebuilt each frame)
///   - descriptor sets (one per frame in flight)
module raster.gpu;

import erupted;
import vulkan.context : VulkanContext, maxFramesInFlight;
import vulkan.buffer : GpuBuffer, createBuffer, uploadBuffer, writeHostBuffer;
import vulkan.pipeline;
import slug.preprocess : BatchBuilder, SlugBatch;
import font.types : GlyphOutline;

/// 4x4 column-major matrix + viewport, packed as 5 x vec4 = 80 bytes.
align(16) struct ParamBlock
{
    float[16] matrix; // slug_matrix[4] (column-major)
    float[4] viewport; // slug_viewport
}

/// Per-glyph vertex (5 x vec4 = 80 bytes, must match pipeline.d)
struct GlyphVertex
{
    float[4] pos; // (x, y, dilX, dilY)  -- screen position + dilation
    float[4] tex; // (u, v, bandBaseHi16_lo16, glyphPackedHi)
    float[4] jac; // inverse Jacobian (jac00, jac01, jac10, jac11)
    float[4] bnd; // (bandScaleX, bandScaleY, bandOffsetX, bandOffsetY)
    float[4] col; // RGBA glyph colour (premultiplied)
}

static assert(GlyphVertex.sizeof == 80);

struct GlyphRenderer
{
    VulkanContext* ctx;

    VkDescriptorSetLayout dsLayout;
    VkPipelineLayout pipelineLayout;
    VkPipeline pipeline;
    VkDescriptorPool descriptorPool;
    VkDescriptorSet[] descriptorSets; // [maxFramesInFlight]

    // Per-frame host-visible UBO
    GpuBuffer[maxFramesInFlight] uboBuffers;

    // Device-local SSBO (rebuilt when font/glyph set changes)
    GpuBuffer curveSSBO;
    GpuBuffer bandSSBO;
    bool ssboDirty = true;

    // Per-frame host-visible vertex buffer
    enum maxVerts = 65536;
    GpuBuffer[maxFramesInFlight] vertexBuffers;

    // Pending vertex data (filled by addGlyph, submitted in draw)
    GlyphVertex[] pendingVerts;

    // BatchBuilder accumulates all glyph data until uploadBuffers() is called
    BatchBuilder batchBuilder;
    // mapping from glyph index in batchBuilder -> bandBase
    uint[] glyphBandBases;

    void init(VulkanContext* vkCtx, string vertSpv, string fragSpv)
    {
        ctx = vkCtx;

        dsLayout = createDescriptorSetLayout(ctx.device);
        pipelineLayout = createPipelineLayout(ctx.device, dsLayout);
        pipeline = createGlyphPipeline(ctx.device, ctx.renderPass,
                                        pipelineLayout, vertSpv, fragSpv);
        descriptorPool = createDescriptorPool(ctx.device, maxFramesInFlight);
        descriptorSets = allocateDescriptorSets(ctx.device, descriptorPool,
                                                dsLayout, maxFramesInFlight);

        foreach (i; 0 .. maxFramesInFlight)
        {
            uboBuffers[i] = createBuffer(ctx.device, ctx.physDev,
                ParamBlock.sizeof,
                VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

            vertexBuffers[i] = createBuffer(ctx.device, ctx.physDev,
                GlyphVertex.sizeof * maxVerts,
                VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        }
    }

    void destroy()
    {
        foreach (i; 0 .. maxFramesInFlight)
        {
            uboBuffers[i].destroy();
            vertexBuffers[i].destroy();
        }
        curveSSBO.destroy();
        bandSSBO.destroy();

        vkDestroyDescriptorPool(ctx.device, descriptorPool, null);
        vkDestroyPipeline(ctx.device, pipeline, null);
        vkDestroyPipelineLayout(ctx.device, pipelineLayout, null);
        vkDestroyDescriptorSetLayout(ctx.device, dsLayout, null);
    }

    /// Add a glyph outline to the batch. Returns the glyph index.
    uint addGlyph(ref const GlyphOutline outline)
    {
        uint bandBase = batchBuilder.addGlyph(outline);
        uint idx = cast(uint)glyphBandBases.length;
        glyphBandBases ~= bandBase;
        ssboDirty = true;
        return idx;
    }

    /// Upload accumulated curve/band data to device-local SSBOs.
    /// Call once after all addGlyph() calls, before the first frame.
    void uploadGlyphBuffers()
    {
        if (!ssboDirty) return;

        curveSSBO.destroy();
        bandSSBO.destroy();

        auto curveBytes = cast(ubyte[])batchBuilder.curveData;
        auto bandBytes = cast(ubyte[])batchBuilder.bandData;

        // Minimum size 4 bytes so Vulkan doesn't complain about zero-size buffers
        VkDeviceSize cSize = curveBytes.length ? curveBytes.length : 4;
        VkDeviceSize bSize = bandBytes.length ? bandBytes.length : 4;

        curveSSBO = createBuffer(ctx.device, ctx.physDev, cSize,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        bandSSBO = createBuffer(ctx.device, ctx.physDev, bSize,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        if (curveBytes.length > 0)
            uploadBuffer(ctx.device, ctx.physDev, ctx.cmdPool, ctx.graphicsQueue,
                         curveSSBO, cast(void[])curveBytes);
        if (bandBytes.length > 0)
            uploadBuffer(ctx.device, ctx.physDev, ctx.cmdPool, ctx.graphicsQueue,
                         bandSSBO, cast(void[])bandBytes);

        // Update all descriptor sets (SSBOs don't change per-frame)
        foreach (i; 0 .. maxFramesInFlight)
            updateDescriptorSet(ctx.device, descriptorSets[i],
                                uboBuffers[i], curveSSBO, bandSSBO);

        ssboDirty = false;
    }

    /// Clear the pending vertex list for a new frame.
    void beginFrame()
    {
        pendingVerts.length = 0;
    }

    /// Emit two triangles for one glyph instance.
    ///
    /// Params:
    ///   glyphIdx = index returned by addGlyph()
    ///   screenX/Y = baseline pen position in screen pixels (y-down)
    ///   scale    = pixels per font unit (= pixelsPerEm / upem)
    ///   color    = RGBA premultiplied
    void addGlyphQuad(uint glyphIdx,
                      float screenX, float screenY,
                      float scale,
                      float[4] color,
                      float fbWidth, float fbHeight)
    {
        if (glyphIdx >= glyphBandBases.length) return;
        if (glyphIdx >= batchBuilder.metas.length) return;

        auto meta = batchBuilder.metas[glyphIdx];
        uint bandBase = glyphBandBases[glyphIdx];

        // font-unit bbox corners
        float x0e = meta.xMin;
        float y0e = meta.yMin;
        float x1e = meta.xMax;
        float y1e = meta.yMax;

        // Screen quad corners (both screen and em space are y-down)
        float s = scale;
        float sx0 = screenX + x0e * s;
        float sy0 = screenY + y0e * s;
        float sx1 = screenX + x1e * s;
        float sy1 = screenY + y1e * s;

        // Dilation: 1.5 px expansion for AA
        float dilX = 1.5f;
        float dilY = 1.5f;

        // Inverse Jacobian: converts screen-pixel dilation back to font-unit delta
        float invS = (s > 0) ? 1.0f / s : 0.0f;
        float[4] jac = [invS, 0.0f, 0.0f, invS];

        // bandBase packed into two 16-bit halves for tex.z
        uint bbLo16 = bandBase & 0xFFFFu;
        uint bbHi16 = (bandBase >> 16) & 0xFFFFu;
        uint texZbits = bbLo16 | (bbHi16 << 16);
        uint texWbits = meta.bandMaxPacked;

        import core.bitop : bswap;
        float texZ = *cast(float*)&texZbits;
        float texW = *cast(float*)&texWbits;

        // 4 corners: TL, TR, BL, BR
        // tex.xy = em-space coordinate of the corner (y-down)
        struct Corner { float px, py, u, v; }
        Corner[4] corners = [
            Corner(sx0 - dilX, sy0 - dilY, x0e, y0e), // TL
            Corner(sx1 + dilX, sy0 - dilY, x1e, y0e), // TR
            Corner(sx0 - dilX, sy1 + dilY, x0e, y1e), // BL
            Corner(sx1 + dilX, sy1 + dilY, x1e, y1e), // BR
        ];

        // Triangle 1: TL, TR, BL
        // Triangle 2: TR, BR, BL
        static immutable int[6] idx = [0, 1, 2, 1, 3, 2];
        foreach (vi; idx)
        {
            auto c = corners[vi];
            GlyphVertex v;
            v.pos = [c.px, c.py, dilX, dilY];
            v.tex = [c.u, c.v, texZ, texW];
            v.jac = jac;
            v.bnd = meta.bnd;
            v.col = color;
            pendingVerts ~= v;
        }
    }

    /// Upload vertex data and record draw commands into cmd.
    void recordDraw(VkCommandBuffer cmd, uint frameIndex,
                    uint fbWidth, uint fbHeight,
                    ParamBlock params)
    {
        if (pendingVerts.length == 0) return;

        // Write UBO
        writeHostBuffer(uboBuffers[frameIndex],
                        cast(const(void)[])(&params)[0 .. 1]);

        // Write vertices
        writeHostBuffer(vertexBuffers[frameIndex],
                        cast(const(void)[])pendingVerts);

        // Bind pipeline + descriptor set
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                pipelineLayout, 0, 1,
                                &descriptorSets[frameIndex], 0, null);

        // Dynamic viewport + scissor
        VkViewport vp;
        vp.x = 0; vp.y = 0;
        vp.width = cast(float)fbWidth;
        vp.height = cast(float)fbHeight;
        vp.minDepth = 0; vp.maxDepth = 1;
        vkCmdSetViewport(cmd, 0, 1, &vp);

        VkRect2D sc;
        sc.offset = VkOffset2D(0, 0);
        sc.extent = VkExtent2D(fbWidth, fbHeight);
        vkCmdSetScissor(cmd, 0, 1, &sc);

        // Bind vertex buffer
        VkDeviceSize offset = 0;
        vkCmdBindVertexBuffers(cmd, 0, 1,
                               &vertexBuffers[frameIndex].buffer, &offset);

        vkCmdDraw(cmd, cast(uint)pendingVerts.length, 1, 0, 0);
    }
}
