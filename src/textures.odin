package main

TEX_SIZE :: 16

Tex :: enum u8 {
	Grass_Top,
	Grass_Side,
	Dirt,
	Stone,
	Sand,
	Planks,
	Core,
}

GRASS_COLOR  :: [3]f32{112, 178, 72}
DIRT_COLOR   :: [3]f32{134, 96, 67}
STONE_COLOR  :: [3]f32{128, 128, 128}
SAND_COLOR   :: [3]f32{219, 207, 163}
PLANKS_COLOR :: [3]f32{162, 130, 78}

// Molten core: dark crust, orange melt and bright yellow hot spots.
@(rodata)
CORE_COLORS := [?][3]f32{{70, 20, 10}, {70, 20, 10}, {200, 70, 15}, {230, 95, 20}, {230, 95, 20}, {245, 120, 25}, {255, 165, 45}, {255, 200, 80}}

// A few discrete brightness steps per pixel read as hand-drawn pixel art rather than smooth noise.
@(rodata)
BRIGHTNESS_STEPS := [?]f32{0.78, 0.86, 0.92, 0.97, 1.0, 1.0, 1.05, 1.12}

// Stone is calmer than soil: a narrower spread of greys.
@(rodata)
STONE_STEPS := [?]f32{0.88, 0.93, 0.97, 1.0, 1.0, 1.03, 1.06, 1.1}

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
	case .Stone:
		color := STONE_COLOR * STONE_STEPS[hash3(x, y, 5) % len(STONE_STEPS)]
		// Short dark horizontal streaks, like cracks between rock layers.
		if hash3(x / 3, y, 6) % 7 == 0 {
			color *= 0.78
		}
		return color
	case .Sand:
		// Fine even grain with the odd darker speck.
		color := SAND_COLOR * STONE_STEPS[hash3(x, y, 7) % len(STONE_STEPS)]
		if hash3(x, y, 8) % 11 == 0 {
			color *= 0.85
		}
		return color
	case .Planks:
		// Four boards 4 pixels high, a dark gap under each, one joint per board at a different spot.
		board := y / 4
		color := PLANKS_COLOR * (0.92 + 0.12 * f32(hash3(board, 0, 9) % 4) / 3)
		color *= 0.96 + 0.08 * f32(hash3(x, y, 10) % 3) / 2 // wood grain
		joint := i32(hash3(board, 1, 9) % TEX_SIZE)
		if y % 4 == 3 || x == joint {
			color *= 0.68
		}
		return color
	case .Core:
		// Blobs two pixels across, so it reads as lumps of crust floating on melt.
		color := CORE_COLORS[hash3(x / 2, y / 2, 11) % len(CORE_COLORS)]
		return color * (0.94 + 0.12 * f32(hash3(x, y, 12) % 3) / 2)
	}
	return {}
}

brightness :: proc(x, y, seed: i32) -> f32 {
	return BRIGHTNESS_STEPS[hash3(x, y, seed) % len(BRIGHTNESS_STEPS)]
}
