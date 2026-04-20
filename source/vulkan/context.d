/// Vulkan instance, device, swapchain, and per-frame sync objects.
module vulkan.context;

import erupted;
import erupted.vulkan_lib_loader : loadGlobalLevelFunctions;
import bindbc.glfw;
import std.string : toStringz;
import std.conv : to;
import core.stdc.string : strcmp;

// Inject glfwGetRequiredInstanceExtensions / glfwCreateWindowSurface etc.
// using erupted Vulkan types. Must call loadGLFW_Vulkan() after loadGLFW().
mixin(bindGLFW_Vulkan);

enum uint maxFramesInFlight = 2;

struct SwapchainSupport
{
    VkSurfaceCapabilitiesKHR caps;
    VkSurfaceFormatKHR[] formats;
    VkPresentModeKHR[] presentModes;
}

struct VulkanContext
{
    VkInstance instance;
    VkPhysicalDevice physDev;
    VkDevice device;
    VkQueue graphicsQueue;
    VkQueue presentQueue;
    uint graphicsFamily;
    uint presentFamily;

    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat swapFormat;
    VkExtent2D swapExtent;
    VkImage[] swapImages;
    VkImageView[] swapImageViews;
    VkFramebuffer[] framebuffers;

    VkRenderPass renderPass;
    VkCommandPool cmdPool;
    VkCommandBuffer[maxFramesInFlight] cmdBuffers;

    VkSemaphore[maxFramesInFlight] imageAvailable;
    VkSemaphore[maxFramesInFlight] renderFinished;
    VkFence[maxFramesInFlight] inFlight;

    uint currentFrame;

    void destroy()
    {
        vkDeviceWaitIdle(device);

        foreach (i; 0 .. maxFramesInFlight)
        {
            vkDestroySemaphore(device, imageAvailable[i], null);
            vkDestroySemaphore(device, renderFinished[i], null);
            vkDestroyFence(device, inFlight[i], null);
        }
        vkDestroyCommandPool(device, cmdPool, null);
        foreach (fb; framebuffers) vkDestroyFramebuffer(device, fb, null);
        foreach (iv; swapImageViews) vkDestroyImageView(device, iv, null);
        vkDestroyRenderPass(device, renderPass, null);
        vkDestroySwapchainKHR(device, swapchain, null);
        vkDestroySurfaceKHR(instance, surface, null);
        vkDestroyDevice(device, null);
        vkDestroyInstance(instance, null);
    }
}

VulkanContext createVulkanContext(GLFWwindow* window, uint width, uint height)
{
    loadGlobalLevelFunctions();
    loadGLFW_Vulkan();

    VulkanContext ctx;

    // --- Instance ---
    {
        uint glfwExtCount;
        const(char*)* glfwExts = glfwGetRequiredInstanceExtensions(&glfwExtCount);

        const(char)*[8] exts;
        uint extCount = glfwExtCount;
        foreach (i; 0 .. glfwExtCount) exts[i] = glfwExts[i];

        const(char)*[1] layers;
        uint layerCount = 0;
        debug
        {
            layers[0] = "VK_LAYER_KHRONOS_validation".ptr;
            layerCount = 1;
        }

        VkApplicationInfo appInfo;
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName = "toy-font-renderer";
        appInfo.apiVersion = VK_API_VERSION_1_2;

        VkInstanceCreateInfo ici;
        ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        ici.pApplicationInfo = &appInfo;
        ici.enabledExtensionCount = extCount;
        ici.ppEnabledExtensionNames = exts.ptr;
        ici.enabledLayerCount = layerCount;
        ici.ppEnabledLayerNames = layers.ptr;
        assert(vkCreateInstance(&ici, null, &ctx.instance) == VK_SUCCESS,
               "vkCreateInstance failed");
        loadInstanceLevelFunctions(ctx.instance);
    }

    // --- Surface ---
    assert(glfwCreateWindowSurface(ctx.instance, window, null, &ctx.surface) == VK_SUCCESS,
           "glfwCreateWindowSurface failed");

    // --- Physical device ---
    {
        uint count;
        vkEnumeratePhysicalDevices(ctx.instance, &count, null);
        assert(count > 0, "No Vulkan physical devices found");
        auto devs = new VkPhysicalDevice[](count);
        vkEnumeratePhysicalDevices(ctx.instance, &count, devs.ptr);

        // Pick first device that supports the required queue families
        foreach (pd; devs)
        {
            uint qCount;
            vkGetPhysicalDeviceQueueFamilyProperties(pd, &qCount, null);
            auto qprops = new VkQueueFamilyProperties[](qCount);
            vkGetPhysicalDeviceQueueFamilyProperties(pd, &qCount, qprops.ptr);

            int gfx = -1, pres = -1;
            foreach (uint i; 0 .. cast(uint)qprops.length)
            {
                ref p = qprops[i];
                if ((p.queueFlags & VK_QUEUE_GRAPHICS_BIT) && gfx < 0)
                    gfx = i;
                VkBool32 sup;
                vkGetPhysicalDeviceSurfaceSupportKHR(pd, i, ctx.surface, &sup);
                if (sup && pres < 0) pres = i;
            }
            if (gfx < 0 || pres < 0) continue;

            // Require VK_KHR_swapchain
            uint extCount;
            vkEnumerateDeviceExtensionProperties(pd, null, &extCount, null);
            auto exts = new VkExtensionProperties[](extCount);
            vkEnumerateDeviceExtensionProperties(pd, null, &extCount, exts.ptr);
            bool hasSwapchain = false;
            foreach (ref e; exts)
            {
                if (strcmp(e.extensionName.ptr, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0)
                    hasSwapchain = true;
            }
            if (!hasSwapchain) continue;

            ctx.physDev = pd;
            ctx.graphicsFamily = gfx;
            ctx.presentFamily = pres;
            break;
        }
        assert(ctx.physDev, "No suitable Vulkan physical device");
    }

    // --- Logical device ---
    {
        float prio = 1.0f;
        VkDeviceQueueCreateInfo[2] qci;
        uint[2] uniqueFamilies = [ctx.graphicsFamily, ctx.presentFamily];
        uint nQueues = (ctx.graphicsFamily == ctx.presentFamily) ? 1 : 2;
        foreach (i; 0 .. nQueues)
        {
            qci[i].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            qci[i].queueFamilyIndex = uniqueFamilies[i];
            qci[i].queueCount = 1;
            qci[i].pQueuePriorities = &prio;
        }

        const(char)*[1] devExts = [VK_KHR_SWAPCHAIN_EXTENSION_NAME];

        VkDeviceCreateInfo dci;
        dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dci.queueCreateInfoCount = nQueues;
        dci.pQueueCreateInfos = qci.ptr;
        dci.enabledExtensionCount = 1;
        dci.ppEnabledExtensionNames = devExts.ptr;
        assert(vkCreateDevice(ctx.physDev, &dci, null, &ctx.device) == VK_SUCCESS);
        loadDeviceLevelFunctions(ctx.device);

        vkGetDeviceQueue(ctx.device, ctx.graphicsFamily, 0, &ctx.graphicsQueue);
        vkGetDeviceQueue(ctx.device, ctx.presentFamily, 0, &ctx.presentQueue);
    }

    createSwapchain(ctx, width, height);
    createRenderPass(ctx);
    createFramebuffers(ctx);
    createCommandPool(ctx);
    createSyncObjects(ctx);

    return ctx;
}

void createSwapchain(ref VulkanContext ctx, uint width, uint height)
{
    // Capabilities
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physDev, ctx.surface, &caps);

    // Format: prefer BGRA8_SRGB / SRGB_NONLINEAR
    uint fmtCount;
    vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physDev, ctx.surface, &fmtCount, null);
    auto fmts = new VkSurfaceFormatKHR[](fmtCount);
    vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physDev, ctx.surface, &fmtCount, fmts.ptr);

    VkSurfaceFormatKHR chosen = fmts[0];
    foreach (ref f; fmts)
    {
        if (f.format == VK_FORMAT_B8G8R8A8_SRGB &&
            f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            chosen = f;
    }

    ctx.swapFormat = chosen.format;

    // Present mode: prefer mailbox, fallback FIFO
    uint pmCount;
    vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.physDev, ctx.surface, &pmCount, null);
    auto pms = new VkPresentModeKHR[](pmCount);
    vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.physDev, ctx.surface, &pmCount, pms.ptr);
    VkPresentModeKHR pm = VK_PRESENT_MODE_FIFO_KHR;
    foreach (p; pms)
    {
        if (p == VK_PRESENT_MODE_MAILBOX_KHR) pm = p;
    }

    // Extent
    if (caps.currentExtent.width != uint.max)
    {
        ctx.swapExtent = caps.currentExtent;
    }
    else
    {
        ctx.swapExtent.width = cast(uint)(width < caps.minImageExtent.width ? caps.minImageExtent.width
                                                                            : width > caps.maxImageExtent.width ? caps.maxImageExtent.width : width);
        ctx.swapExtent.height = cast(uint)(height < caps.minImageExtent.height ? caps.minImageExtent.height
                                                                               : height > caps.maxImageExtent.height ? caps.maxImageExtent.height : height);
    }

    uint imgCount = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && imgCount > caps.maxImageCount)
        imgCount = caps.maxImageCount;

    uint[2] qfamilies = [ctx.graphicsFamily, ctx.presentFamily];
    bool sameFamily = ctx.graphicsFamily == ctx.presentFamily;

    VkSwapchainCreateInfoKHR sci;
    sci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    sci.surface = ctx.surface;
    sci.minImageCount = imgCount;
    sci.imageFormat = chosen.format;
    sci.imageColorSpace = chosen.colorSpace;
    sci.imageExtent = ctx.swapExtent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.imageSharingMode = sameFamily ? VK_SHARING_MODE_EXCLUSIVE : VK_SHARING_MODE_CONCURRENT;
    sci.queueFamilyIndexCount = sameFamily ? 0 : 2;
    sci.pQueueFamilyIndices = sameFamily ? null : qfamilies.ptr;
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = pm;
    sci.clipped = VK_TRUE;
    assert(vkCreateSwapchainKHR(ctx.device, &sci, null, &ctx.swapchain) == VK_SUCCESS);

    // Retrieve images
    uint swapImgCount;
    vkGetSwapchainImagesKHR(ctx.device, ctx.swapchain, &swapImgCount, null);
    ctx.swapImages = new VkImage[](swapImgCount);
    vkGetSwapchainImagesKHR(ctx.device, ctx.swapchain, &swapImgCount, ctx.swapImages.ptr);

    // Image views
    ctx.swapImageViews = new VkImageView[](swapImgCount);
    foreach (uint i; 0 .. cast(uint)ctx.swapImages.length)
    {
        auto img = ctx.swapImages[i];
        VkImageViewCreateInfo ivci;
        ivci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ivci.image = img;
        ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = ctx.swapFormat;
        ivci.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
        ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        ivci.subresourceRange.baseMipLevel = 0;
        ivci.subresourceRange.levelCount = 1;
        ivci.subresourceRange.baseArrayLayer = 0;
        ivci.subresourceRange.layerCount = 1;
        assert(vkCreateImageView(ctx.device, &ivci, null, &ctx.swapImageViews[i]) == VK_SUCCESS);
    }
}

void createRenderPass(ref VulkanContext ctx)
{
    VkAttachmentDescription col;
    col.format = ctx.swapFormat;
    col.samples = VK_SAMPLE_COUNT_1_BIT;
    col.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    col.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    col.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    col.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    col.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    col.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference colRef;
    colRef.attachment = 0;
    colRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription sub;
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &colRef;

    VkSubpassDependency dep;
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.srcAccessMask = 0;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo rpci;
    rpci.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpci.attachmentCount = 1;
    rpci.pAttachments = &col;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &sub;
    rpci.dependencyCount = 1;
    rpci.pDependencies = &dep;
    assert(vkCreateRenderPass(ctx.device, &rpci, null, &ctx.renderPass) == VK_SUCCESS);
}

void createFramebuffers(ref VulkanContext ctx)
{
    ctx.framebuffers = new VkFramebuffer[](ctx.swapImageViews.length);
    foreach (uint i; 0 .. cast(uint)ctx.swapImageViews.length)
    {
        auto iv = ctx.swapImageViews[i];
        VkImageView[1] attachments = [iv];
        VkFramebufferCreateInfo fci;
        fci.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fci.renderPass = ctx.renderPass;
        fci.attachmentCount = 1;
        fci.pAttachments = attachments.ptr;
        fci.width = ctx.swapExtent.width;
        fci.height = ctx.swapExtent.height;
        fci.layers = 1;
        assert(vkCreateFramebuffer(ctx.device, &fci, null, &ctx.framebuffers[i]) == VK_SUCCESS);
    }
}

void createCommandPool(ref VulkanContext ctx)
{
    VkCommandPoolCreateInfo pci;
    pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex = ctx.graphicsFamily;
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    assert(vkCreateCommandPool(ctx.device, &pci, null, &ctx.cmdPool) == VK_SUCCESS);

    VkCommandBufferAllocateInfo ai;
    ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = ctx.cmdPool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = maxFramesInFlight;
    assert(vkAllocateCommandBuffers(ctx.device, &ai, ctx.cmdBuffers.ptr) == VK_SUCCESS);
}

void createSyncObjects(ref VulkanContext ctx)
{
    VkSemaphoreCreateInfo sci;
    sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    VkFenceCreateInfo fci;
    fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;

    foreach (i; 0 .. maxFramesInFlight)
    {
        assert(vkCreateSemaphore(ctx.device, &sci, null, &ctx.imageAvailable[i]) == VK_SUCCESS);
        assert(vkCreateSemaphore(ctx.device, &sci, null, &ctx.renderFinished[i]) == VK_SUCCESS);
        assert(vkCreateFence(ctx.device, &fci, null, &ctx.inFlight[i]) == VK_SUCCESS);
    }
}
