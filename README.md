# toy-font-renderer

A GPU font renderer in D based on the [Slug algorithm](https://jcgt.org/published/0006/02/02/).
Renders glyph outlines directly in the fragment shader without texture atlases.
Uses Vulkan storage buffers instead of the reference implementation's index textures for curve/band data.

## Dependencies

- LDC
- Vulkan SDK (`glslangValidator`, `libvulkan`)
- GLFW
- HarfBuzz

Ubuntu/Debian:

```sh
sudo apt install libglfw3-dev libharfbuzz-dev libvulkan-dev vulkan-validationlayers
```

## Build & Run

```sh
dub run
```

## License

MIT

Shader code is based on [Eric Lengyel's Slug reference implementation](https://github.com/EricLengyel/Slug)
(MIT OR Apache-2.0, Copyright 2017 Eric Lengyel).
