package main

// 16 bytes: position relative to the chunk anchor, then texture u, v, texture layer and brightness.
Vertex :: struct {
	pos:  [3]f32,
	info: [4]u8,
}

// The six sides of a block in its face's local grid: Up points away from the planet centre.
Side :: enum u8 {
	East,  // +x
	West,  // -x
	Up,    // +y
	Down,  // -y
	South, // +z
	North, // -z
}

@(rodata)
SIDE_NORMAL := [Side][3]i32 {
	.East  = {+1, 0, 0},
	.West  = {-1, 0, 0},
	.Up    = {0, +1, 0},
	.Down  = {0, -1, 0},
	.South = {0, 0, +1},
	.North = {0, 0, -1},
}

// Bottom-left, bottom-right, top-right, top-left: counter-clockwise when seen from outside the block.
@(rodata)
SIDE_CORNERS := [Side][4][3]i32 {
	.East  = {{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
	.West  = {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
	.Up    = {{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
	.Down  = {{1, 0, 1}, {0, 0, 1}, {0, 0, 0}, {1, 0, 0}},
	.South = {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	.North = {{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
}

// Texture row 0 is the top of the image, so v = 0 goes on the top edge.
@(rodata)
CORNER_UV := [4][2]u8{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// Fixed brightness per side gives the classic blocky look without real lighting (255 = full).
@(rodata)
SIDE_SHADE := [Side]u8 {
	.East  = 153,
	.West  = 153,
	.Up    = 255,
	.Down  = 128,
	.South = 204,
	.North = 204,
}

block_texture :: proc(block: Block, side: Side) -> Tex {
	#partial switch block {
	case .Grass:
		#partial switch side {
		case .Up:
			return .Grass_Top
		case .Down:
			return .Dirt
		}
		return .Grass_Side
	case .Stone:
		return .Stone
	case .Sand:
		return .Sand
	case .Planks:
		return .Planks
	case .Core:
		return .Core
	}
	return .Dirt
}

// Emits only the sides that touch air; sides hidden between two blocks are never drawn.
// Corners are bent onto the ball through face_to_world, so neighbouring blocks share exact corners.
build_chunk_mesh :: proc(w: ^World, chunk: ^Chunk, out: ^[dynamic]Vertex) {
	clear(out)
	face := chunk.pos.face
	base := [3]i32{chunk.pos.x, chunk.pos.y, chunk.pos.z} * CHUNK_SIZE
	for y in i32(0) ..< CHUNK_SIZE {
		for z in i32(0) ..< CHUNK_SIZE {
			for x in i32(0) ..< CHUNK_SIZE {
				block := chunk.blocks[block_index(x, y, z)]
				if block == .Air {
					continue
				}
				for side in Side {
					n := [3]i32{x, y, z} + SIDE_NORMAL[side]
					neighbor: Block
					if n.x >= 0 && n.x < CHUNK_SIZE && n.y >= 0 && n.y < CHUNK_SIZE && n.z >= 0 && n.z < CHUNK_SIZE {
						neighbor = chunk.blocks[block_index(n.x, n.y, n.z)]
					} else {
						g := base + n
						neighbor = world_get_block(w, face, g.x, g.y, g.z)
					}
					if neighbor != .Air {
						continue
					}
					layer := u8(block_texture(block, side))
					// The molten core glows, so it is equally bright from every side.
					shade := u8(255) if block == .Core else SIDE_SHADE[side]
					for corner, i in SIDE_CORNERS[side] {
						g := ([3]f64)(base + [3]i32{x, y, z} + corner)
						pos := face_to_world(face, g.x, g.z, g.y) - chunk.anchor
						uv := CORNER_UV[i]
						append(out, Vertex{pos = ([3]f32)(pos), info = {uv.x, uv.y, layer, shade}})
					}
				}
			}
		}
	}
}
