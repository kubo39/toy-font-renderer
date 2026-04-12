/// Vulkan graphics pipeline for Slug glyph rendering
module vulkan.pipeline;

import erupted;
import std.file : read;
import std.conv : to;

private VkShaderModule loadSpv(VkDevice device, string path)
{
    ubyte[] code = cast(ubyte[])read(path);
    VkShaderModuleCreateInfo ci;
    ci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = code.length;
    ci.pCode = cast(const(uint)*)code.ptr;
    VkShaderModule m;
    assert(vkCreateShaderModule(device, &ci, null, &m) == VK_SUCCESS,
           "Failed to load SPIR-V: " ~ path);
    return m;
}

/// Bindings:
///   0 = uniform buffer     (ParamBlock, vertex stage)
///   1 = storage buffer     (CurveBuffer, fragment stage)
///   2 = storage buffer     (BandBuffer, fragment stage)
VkDescriptorSetLayout createDescriptorSetLayout(VkDevice device)
{
    VkDescriptorSetLayoutBinding[3] binds;

    // binding 0: uniform buffer (ParamBlock)
    binds[0].binding = 0;
    binds[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    binds[0].descriptorCount = 1;
    binds[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;

    // binding 1: storage buffer (CurveBuffer)
    binds[1].binding = 1;
    binds[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    binds[1].descriptorCount = 1;
    binds[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // binding 2: storage buffer (BandBuffer)
    binds[2].binding = 2;
    binds[2].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    binds[2].descriptorCount = 1;
    binds[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    VkDescriptorSetLayoutCreateInfo ci;
    ci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    ci.bindingCount = cast(uint)binds.length;
    ci.pBindings = binds.ptr;

    VkDescriptorSetLayout layout;
    assert(vkCreateDescriptorSetLayout(device, &ci, null, &layout) == VK_SUCCESS);
    return layout;
}

VkPipelineLayout createPipelineLayout(VkDevice device,
                                       VkDescriptorSetLayout dsLayout)
{
    VkPipelineLayoutCreateInfo ci;
    ci.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ci.setLayoutCount = 1;
    ci.pSetLayouts = &dsLayout;

    VkPipelineLayout layout;
    assert(vkCreatePipelineLayout(device, &ci, null, &layout) == VK_SUCCESS);
    return layout;
}

/// GlyphVertex layout (stride = 80 bytes, all vec4):
///   location 0: pos  (vec4)
///   location 1: tex  (vec4)
///   location 2: jac  (vec4)
///   location 3: bnd  (vec4)
///   location 4: col  (vec4)
VkPipeline createGlyphPipeline(VkDevice device,
                                VkRenderPass renderPass,
                                VkPipelineLayout pipelineLayout,
                                string vertSpvPath,
                                string fragSpvPath)
{
    VkShaderModule vertMod = loadSpv(device, vertSpvPath);
    VkShaderModule fragMod = loadSpv(device, fragSpvPath);
    scope(exit)
    {
        vkDestroyShaderModule(device, vertMod, null);
        vkDestroyShaderModule(device, fragMod, null);
    }

    // Shader stages
    VkPipelineShaderStageCreateInfo[2] stages;
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module_ = vertMod;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module_ = fragMod;
    stages[1].pName = "main";

    // Vertex input: single binding, stride 80
    VkVertexInputBindingDescription vbind;
    vbind.binding = 0;
    vbind.stride = 80; // 5 x vec4 x 4 bytes
    vbind.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

    VkVertexInputAttributeDescription[5] vattrs;
    foreach (i; 0 .. 5)
    {
        vattrs[i].location = i;
        vattrs[i].binding = 0;
        vattrs[i].format = VK_FORMAT_R32G32B32A32_SFLOAT;
        vattrs[i].offset = i * 16; // 4 floats x 4 bytes = 16 bytes each
    }

    VkPipelineVertexInputStateCreateInfo vis;
    vis.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vis.vertexBindingDescriptionCount = 1;
    vis.pVertexBindingDescriptions = &vbind;
    vis.vertexAttributeDescriptionCount = cast(uint)vattrs.length;
    vis.pVertexAttributeDescriptions = vattrs.ptr;

    // Input assembly
    VkPipelineInputAssemblyStateCreateInfo ias;
    ias.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ias.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    // Viewport / scissor (dynamic)
    VkPipelineViewportStateCreateInfo vps;
    vps.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vps.viewportCount = 1;
    vps.scissorCount = 1;

    // Rasterizer
    VkPipelineRasterizationStateCreateInfo ras;
    ras.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    ras.polygonMode = VK_POLYGON_MODE_FILL;
    ras.cullMode = VK_CULL_MODE_NONE;
    ras.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    ras.depthBiasConstantFactor = 0.0f;
    ras.depthBiasClamp = 0.0f;
    ras.depthBiasSlopeFactor = 0.0f;
    ras.lineWidth = 1.0f;

    // Multisample (off)
    VkPipelineMultisampleStateCreateInfo ms;
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    // Alpha blending: premultiplied alpha for text
    VkPipelineColorBlendAttachmentState cba;
    cba.blendEnable = VK_TRUE;
    cba.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
    cba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.colorBlendOp = VK_BLEND_OP_ADD;
    cba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    cba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cba.alphaBlendOp = VK_BLEND_OP_ADD;
    cba.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                         VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo cbs;
    cbs.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cbs.attachmentCount = 1;
    cbs.pAttachments = &cba;
    cbs.blendConstants = [0.0f, 0.0f, 0.0f, 0.0f];

    // Dynamic state: viewport + scissor
    VkDynamicState[2] dynStates = [
        VK_DYNAMIC_STATE_VIEWPORT,
        VK_DYNAMIC_STATE_SCISSOR
    ];
    VkPipelineDynamicStateCreateInfo dyn;
    dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn.dynamicStateCount = cast(uint)dynStates.length;
    dyn.pDynamicStates = dynStates.ptr;

    VkGraphicsPipelineCreateInfo pci;
    pci.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pci.stageCount = cast(uint)stages.length;
    pci.pStages = stages.ptr;
    pci.pVertexInputState = &vis;
    pci.pInputAssemblyState = &ias;
    pci.pViewportState = &vps;
    pci.pRasterizationState = &ras;
    pci.pMultisampleState = &ms;
    pci.pColorBlendState = &cbs;
    pci.pDynamicState = &dyn;
    pci.layout = pipelineLayout;
    pci.renderPass = renderPass;
    pci.subpass = 0;

    VkPipeline pipeline;
    assert(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pci, null, &pipeline) == VK_SUCCESS,
           "Failed to create glyph pipeline");
    return pipeline;
}

/// Pool sized for `frameCount` sets, each with 1 UBO + 2 SSBOs.
VkDescriptorPool createDescriptorPool(VkDevice device, uint frameCount)
{
    VkDescriptorPoolSize[2] sizes;
    sizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    sizes[0].descriptorCount = frameCount;
    sizes[1].type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    sizes[1].descriptorCount = frameCount * 2; // curve + band

    VkDescriptorPoolCreateInfo ci;
    ci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    ci.maxSets = frameCount;
    ci.poolSizeCount = cast(uint)sizes.length;
    ci.pPoolSizes = sizes.ptr;

    VkDescriptorPool pool;
    assert(vkCreateDescriptorPool(device, &ci, null, &pool) == VK_SUCCESS);
    return pool;
}

/// Allocate `frameCount` descriptor sets from the pool.
VkDescriptorSet[] allocateDescriptorSets(VkDevice device,
                                          VkDescriptorPool pool,
                                          VkDescriptorSetLayout layout,
                                          uint frameCount)
{
    VkDescriptorSetLayout[] layouts = new VkDescriptorSetLayout[](frameCount);
    foreach (ref l; layouts) l = layout;

    VkDescriptorSetAllocateInfo ai;
    ai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    ai.descriptorPool = pool;
    ai.descriptorSetCount = frameCount;
    ai.pSetLayouts = layouts.ptr;

    VkDescriptorSet[] sets = new VkDescriptorSet[](frameCount);
    assert(vkAllocateDescriptorSets(device, &ai, sets.ptr) == VK_SUCCESS);
    return sets;
}

import vulkan.buffer : GpuBuffer;

/// Update one descriptor set with the UBO, curve SSBO, and band SSBO.
void updateDescriptorSet(VkDevice device, VkDescriptorSet ds,
                          ref GpuBuffer ubo,
                          ref GpuBuffer curveSSBO,
                          ref GpuBuffer bandSSBO)
{
    VkDescriptorBufferInfo[3] bufs;
    bufs[0].buffer = ubo.buffer; bufs[0].offset = 0; bufs[0].range = ubo.size;
    bufs[1].buffer = curveSSBO.buffer; bufs[1].offset = 0; bufs[1].range = curveSSBO.size;
    bufs[2].buffer = bandSSBO.buffer; bufs[2].offset = 0; bufs[2].range = bandSSBO.size;

    VkWriteDescriptorSet[3] writes;
    writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[0].dstSet = ds;
    writes[0].dstBinding = 0;
    writes[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    writes[0].descriptorCount = 1;
    writes[0].pBufferInfo = &bufs[0];

    writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[1].dstSet = ds;
    writes[1].dstBinding = 1;
    writes[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[1].descriptorCount = 1;
    writes[1].pBufferInfo = &bufs[1];

    writes[2].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[2].dstSet = ds;
    writes[2].dstBinding = 2;
    writes[2].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[2].descriptorCount = 1;
    writes[2].pBufferInfo = &bufs[2];

    vkUpdateDescriptorSets(device, cast(uint)writes.length, writes.ptr, 0, null);
}
