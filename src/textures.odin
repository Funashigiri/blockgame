package main

TEX_SIZE :: 16

Tex :: enum u8 {
	Grass_Top,
	Grass_Side,
	Dirt,
}

GRASS_COLOR :: [3]f32{112, 178, 72}
DIRT_COLOR  :: [3]f32{134, 96, 67}

// A few discrete brightness steps per pixel read as hand-drawn pixel art rather than smooth noise.
@(rodata)
BRIGHTNESS_STEPS := [?]f32{0.78, 0.86, 0.92, 0.97, 1.0, 1.0, 1.05, 1.12}

// Every block texture is drawn here pixel by pixel, so the game ships no borrowed image files.
// Returns one RGBA 16x16 layer per Tex, back to back.
generate_textures :: proc(allocator := context.allocator) -> []u8 {
	LAYER_BYTES :: TEX_SIZE * TEX_SIZE * 4
	pixels := make([]u8, LAYER_BYTES * len(Tex), allocator)
	for tex in Tex {
		for y in i32(0) ..< TEX_SIZE {
			for x in i32(0) ..< TEX_SIZE {
				color := texel(tex, x, y)
				i := int(tex) * LAYER_BYTES + int(y * TEX_SIZE + x) * 4
				pixels[i + 0] = u8(clamp(color.r, 0, 255))
				pixels[i + 1] = u8(clamp(color.g, 0, 255))
				pixels[i + 2] = u8(clamp(color.b, 0, 255))
				pixels[i + 3] = 255
			}
		}
	}
	return pixels
}

texel :: proc(tex: Tex, x, y: i32) -> [3]f32 {
	switch tex {
	case .Grass_Top:
		return GRASS_COLOR * brightness(x, y, 1)
	case .Dirt:
		return DIRT_COLOR * brightness(x, y, 2)
	case .Grass_Side:
		// Green fringe along the top that hangs 3-5 pixels down with a ragged edge.
		fringe := 3 + i32(hash3(x, 0, 3) % 3)
		if y < fringe {
			return GRASS_COLOR * brightness(x, y, 1)
		}
		return DIRT_COLOR * brightness(x, y, 2)
	}
	return {}
}

brightness :: proc(x, y, seed: i32) -> f32 {
	return BRIGHTNESS_STEPS[hash3(x, y, seed) % len(BRIGHTNESS_STEPS)]
}
