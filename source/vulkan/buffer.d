/// Vulkan buffer + memory helpers
module vulkan.buffer;

import erupted;
import std.exception : enforce;
import std.string : format;

uint findMemoryType(VkPhysicalDevice physDev, uint typeBits,
                    VkMemoryPropertyFlags props)
{
    VkPhysicalDeviceMemoryProperties memProps;
    vkGetPhysicalDeviceMemoryProperties(physDev, &memProps);

    foreach (i; 0 .. memProps.memoryTypeCount)
    {
        if ((typeBits & (1 << i)) &&
            (memProps.memoryTypes[i].propertyFlags & props) == props)
            return i;
    }
    assert(false, "No suitable memory type found");
}

struct GpuBuffer
{
    VkDevice device;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize size;

    void destroy()
    {
        if (buffer) { vkDestroyBuffer(device, buffer, null); buffer = null; }
        if (memory) { vkFreeMemory(device, memory, null); memory = null; }
    }
}

GpuBuffer createBuffer(VkDevice device, VkPhysicalDevice physDev,
                        VkDeviceSize size, VkBufferUsageFlags usage,
                        VkMemoryPropertyFlags props)
{
    GpuBuffer result;
    result.device = device;
    result.size = size;

    VkBufferCreateInfo ci;
    ci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    ci.size = size;
    ci.usage = usage;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    assert(vkCreateBuffer(device, &ci, null, &result.buffer) == VK_SUCCESS);

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, result.buffer, &req);

    VkMemoryAllocateInfo ai;
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = findMemoryType(physDev, req.memoryTypeBits, props);
    assert(vkAllocateMemory(device, &ai, null, &result.memory) == VK_SUCCESS);
    assert(vkBindBufferMemory(device, result.buffer, result.memory, 0) == VK_SUCCESS);

    return result;
}

/// Upload data via a staging buffer (host-visible -> device-local).
void uploadBuffer(VkDevice device, VkPhysicalDevice physDev,
                  VkCommandPool cmdPool, VkQueue queue,
                  ref GpuBuffer dst, const(void)[] data)
{
    GpuBuffer staging = createBuffer(device, physDev, data.length,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    scope(exit) staging.destroy();

    void* mapped;
    vkMapMemory(device, staging.memory, 0, data.length, 0, &mapped);
    import core.stdc.string : memcpy;
    memcpy(mapped, data.ptr, data.length);
    vkUnmapMemory(device, staging.memory);

    // One-shot command buffer for the copy
    VkCommandBufferAllocateInfo ai;
    ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = cmdPool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(device, &ai, &cmd);

    VkCommandBufferBeginInfo bi;
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);

    VkBufferCopy copy;
    copy.size = data.length;
    vkCmdCopyBuffer(cmd, staging.buffer, dst.buffer, 1, &copy);

    vkEndCommandBuffer(cmd);

    VkSubmitInfo si;
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(queue);
    vkFreeCommandBuffers(device, cmdPool, 1, &cmd);
}

/// Upload data into a host-visible buffer (for uniform / vertex buffers rebuilt each frame).
void writeHostBuffer(ref GpuBuffer buf, const(void)[] data)
{
    assert(data.length <= buf.size);
    void* mapped;
    vkMapMemory(buf.device, buf.memory, 0, data.length, 0, &mapped);
    import core.stdc.string : memcpy;
    memcpy(mapped, data.ptr, data.length);
    vkUnmapMemory(buf.device, buf.memory);
}
