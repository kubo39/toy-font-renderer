module app;

import erupted;
import bindbc.glfw;
import vulkan.context : VulkanContext, createVulkanContext, maxFramesInFlight;
import vulkan.pipeline;
import raster.gpu : GlyphRenderer, ParamBlock;
import layout.layout : GlyphCache, layoutText;
import font.hb;
import std.stdio : stderr;

// Row-major: slug_matrix[i] = row i, used as row vectors in glyph.vert.
// x_ndc = x*(2/w) - 1,  y_ndc = y*(2/h) - 1
float[16] orthoMatrix(float w, float h)
{
    float[16] m = 0;
    m[0] = 2.0f / w;  // row0: (2/w,  0,   0,  -1)
    m[3] = -1.0f;
    m[5] = 2.0f / h;  // row1: ( 0,  2/h,  0,  -1)
    m[7] = -1.0f;
    m[10] = 1.0f;      // row2: ( 0,   0,   1,   0)
    m[15] = 1.0f;      // row3: ( 0,   0,   0,   1)
    return m;
}

enum fontPath = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
enum renderText = "こんにちは世界！";

int main(string[] args)
{
    // Load GLFW
    {
        auto r = loadGLFW();
        if (r == GLFWSupport.noLibrary)
        {
            stderr.writeln("GLFW library not found");
            return 1;
        }
    }
    if (!glfwInit())
    {
        stderr.writeln("glfwInit failed");
        return 1;
    }
    scope(exit) glfwTerminate();

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);

    enum uint width = 1280;
    enum uint height = 720;

    GLFWwindow* window = glfwCreateWindow(width, height, "Toy Font Renderer", null, null);
    if (window is null)
    {
        stderr.writeln("glfwCreateWindow failed");
        return 1;
    }
    scope(exit) glfwDestroyWindow(window);

    VulkanContext vkCtx = createVulkanContext(window, width, height);
    scope(exit) vkCtx.destroy();

    GlyphRenderer renderer;
    renderer.init(&vkCtx, "shaders/glyph.vert.spv", "shaders/glyph.frag.spv");
    scope(exit) renderer.destroy();

    // Load font with HarfBuzz
    import std.string : toStringz;
    hb_blob_t* blob = hb_blob_create_from_file(fontPath.toStringz);
    assert(blob !is null, "Failed to load font file");
    scope(exit) hb_blob_destroy(blob);

    hb_face_t* face = hb_face_create(blob, 0);
    assert(face !is null, "Failed to create font face");
    scope(exit) hb_face_destroy(face);

    hb_font_t* font = hb_font_create(face);
    assert(font !is null, "Failed to create font");
    scope(exit) hb_font_destroy(font);

    float upem = cast(float)hb_face_get_upem(face);
    stderr.writefln!"upem = %s"(upem);

    GlyphCache cache;
    cache.init(font, upem);

    // Pre-load glyphs for the render text (via shaping)
    {
        auto glyphs = layoutText(cache, renderer, renderText, 0, 0, 48.0f);
        stderr.writefln!"pre-loaded %s shaped glyphs"(glyphs.length);
    }

    stderr.writefln!"total: glyphs=%s curves=%s(vec4) bands=%s(uvec2)"(
        renderer.batchBuilder.metas.length,
        renderer.batchBuilder.curveData.length / 4,
        renderer.batchBuilder.bandData.length / 2);

    renderer.uploadGlyphBuffers();

    float w = cast(float)vkCtx.swapExtent.width;
    float h = cast(float)vkCtx.swapExtent.height;

    ParamBlock params;
    params.matrix = orthoMatrix(w, h);
    params.viewport = [w, h, 0.0f, 0.0f];

    enum float pixelsPerEm = 48.0f;
    float scale = pixelsPerEm / upem; // pixels per font unit
    float penX = 50.0f;
    float penY = h * 0.5f;

    // Render loop
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        uint frame = vkCtx.currentFrame;

        vkWaitForFences(vkCtx.device, 1, &vkCtx.inFlight[frame], VK_TRUE, ulong.max);

        uint imageIndex;
        VkResult acqRes = vkAcquireNextImageKHR(vkCtx.device, vkCtx.swapchain,
                                                 ulong.max,
                                                 vkCtx.imageAvailable[frame],
                                                 VK_NULL_HANDLE, &imageIndex);
        if (acqRes == VK_ERROR_OUT_OF_DATE_KHR)
            continue;

        vkResetFences(vkCtx.device, 1, &vkCtx.inFlight[frame]);

        VkCommandBuffer cmd = vkCtx.cmdBuffers[frame];
        vkResetCommandBuffer(cmd, 0);

        VkCommandBufferBeginInfo bi;
        bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        vkBeginCommandBuffer(cmd, &bi);

        VkClearValue clearVal;
        clearVal.color.float32 = [0.1f, 0.1f, 0.1f, 1.0f];

        VkRenderPassBeginInfo rpbi;
        rpbi.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpbi.renderPass = vkCtx.renderPass;
        rpbi.framebuffer = vkCtx.framebuffers[imageIndex];
        rpbi.renderArea.offset = VkOffset2D(0, 0);
        rpbi.renderArea.extent = vkCtx.swapExtent;
        rpbi.clearValueCount = 1;
        rpbi.pClearValues = &clearVal;
        vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);

        renderer.beginFrame();

        auto glyphs = layoutText(cache, renderer, renderText, penX, penY, pixelsPerEm);
        float[4] white = [1.0f, 1.0f, 1.0f, 1.0f];
        foreach (ref gi; glyphs)
            renderer.addGlyphQuad(gi.glyphIdx, gi.x, gi.y, scale, white, w, h);

        renderer.recordDraw(cmd, frame,
                             vkCtx.swapExtent.width, vkCtx.swapExtent.height,
                             params);

        vkCmdEndRenderPass(cmd);
        vkEndCommandBuffer(cmd);

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo si;
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.waitSemaphoreCount = 1;
        si.pWaitSemaphores = &vkCtx.imageAvailable[frame];
        si.pWaitDstStageMask = &waitStage;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        si.signalSemaphoreCount = 1;
        si.pSignalSemaphores = &vkCtx.renderFinished[frame];
        vkQueueSubmit(vkCtx.graphicsQueue, 1, &si, vkCtx.inFlight[frame]);

        VkPresentInfoKHR pi;
        pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        pi.waitSemaphoreCount = 1;
        pi.pWaitSemaphores = &vkCtx.renderFinished[frame];
        pi.swapchainCount = 1;
        pi.pSwapchains = &vkCtx.swapchain;
        pi.pImageIndices = &imageIndex;
        vkQueuePresentKHR(vkCtx.presentQueue, &pi);

        vkCtx.currentFrame = (frame + 1) % maxFramesInFlight;
    }

    vkDeviceWaitIdle(vkCtx.device);
    return 0;
}
