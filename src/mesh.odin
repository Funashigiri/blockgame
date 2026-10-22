package main

Vertex :: struct {
	pos:   [3]f32,
	uv:    [2]f32,
	layer: f32,
	shade: f32,
}

Face :: enum u8 {
	East,  // +X
	West,  // -X
	Up,    // +Y
	Down,  // -Y
	South, // +Z
	North, // -Z
}

@(rodata)
FACE_NORMAL := [Face][3]i32 {
	.East  = {+1, 0, 0},
	.West  = {-1, 0, 0},
	.Up    = {0, +1, 0},
	.Down  = {0, -1, 0},
	.South = {0, 0, +1},
	.North = {0, 0, -1},
}

// Bottom-left, bottom-right, top-right, top-left: counter-clockwise when seen from outside the block.
@(rodata)
FACE_CORNERS := [Face][4][3]f32 {
	.East  = {{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
	.West  = {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
	.Up    = {{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
	.Down  = {{1, 0, 1}, {0, 0, 1}, {0, 0, 0}, {1, 0, 0}},
	.South = {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	.North = {{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
}

// Texture row 0 is the top of the image, so v = 0 goes on the top edge.
@(rodata)
CORNER_UV := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// Fixed brightness per face direction gives the classic blocky look without real lighting.
@(rodata)
FACE_SHADE := [Face]f32 {
	.East  = 0.6,
	.West  = 0.6,
	.Up    = 1.0,
	.Down  = 0.5,
	.South = 0.8,
	.North = 0.8,
}

block_texture :: proc(block: Block, face: Face) -> Tex {
	#partial switch block {
	case .Grass:
		#partial switch face {
		case .Up:
			return .Grass_Top
		case .Down:
			return .Dirt
		}
		return .Grass_Side
	}
	return .Dirt
}

// Emits only the faces that touch air; faces hidden between two blocks are never drawn.
build_chunk_mesh :: proc(w: ^World, chunk: ^Chunk, out: ^[dynamic]Vertex) {
	clear(out)
	base := chunk.pos * CHUNK_SIZE
	for y in i32(0) ..< CHUNK_SIZE {
		for z in i32(0) ..< CHUNK_SIZE {
			for x in i32(0) ..< CHUNK_SIZE {
				block := chunk.blocks[block_index(x, y, z)]
				if block == .Air {
					continue
				}
				for face in Face {
					n := [3]i32{x, y, z} + FACE_NORMAL[face]
					neighbor: Block
					if n.x >= 0 && n.x < CHUNK_SIZE && n.y >= 0 && n.y < CHUNK_SIZE && n.z >= 0 && n.z < CHUNK_SIZE {
						neighbor = chunk.blocks[block_index(n.x, n.y, n.z)]
					} else {
						world_pos := base + n
						neighbor = world_get_block(w, world_pos.x, world_pos.y, world_pos.z)
					}
					if neighbor != .Air {
						continue
					}
					layer := f32(u8(block_texture(block, face)))
					shade := FACE_SHADE[face]
					origin := [3]f32{f32(x), f32(y), f32(z)}
					for corner, i in FACE_CORNERS[face] {
						append(out, Vertex{pos = origin + corner, uv = CORNER_UV[i], layer = layer, shade = shade})
					}
				}
			}
		}
	}
}
