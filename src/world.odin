package main

import "core:math"

CHUNK_SIZE   :: 16
CHUNK_SHIFT  :: 4
CHUNK_MASK   :: CHUNK_SIZE - 1
CHUNK_VOLUME :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

ISLAND_RADIUS :: 40
ISLAND_TOP    :: 40

Block :: enum u8 {
	Air,
	Grass,
	Dirt,
}

Chunk_Pos :: [3]i32

Chunk :: struct {
	pos:    Chunk_Pos,
	blocks: [CHUNK_VOLUME]Block,
	mesh:   Chunk_Mesh,
}

World :: struct {
	chunks: map[Chunk_Pos]^Chunk,
}

block_index :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return (y * CHUNK_SIZE + z) * CHUNK_SIZE + x
}

// Arithmetic shift and mask act as floor division and modulo,
// so negative coordinates land in the right chunk.
world_get_block :: proc(w: ^World, x, y, z: i32) -> Block {
	chunk := w.chunks[Chunk_Pos{x >> CHUNK_SHIFT, y >> CHUNK_SHIFT, z >> CHUNK_SHIFT}]
	if chunk == nil {
		return .Air
	}
	return chunk.blocks[block_index(x & CHUNK_MASK, y & CHUNK_MASK, z & CHUNK_MASK)]
}

world_set_block :: proc(w: ^World, x, y, z: i32, block: Block) {
	pos := Chunk_Pos{x >> CHUNK_SHIFT, y >> CHUNK_SHIFT, z >> CHUNK_SHIFT}
	chunk := w.chunks[pos]
	if chunk == nil {
		if block == .Air {
			return
		}
		chunk = new(Chunk)
		chunk.pos = pos
		w.chunks[pos] = chunk
	}
	chunk.blocks[block_index(x & CHUNK_MASK, y & CHUNK_MASK, z & CHUNK_MASK)] = block
}

// A flat lawn floating in the sky, with an upside-down cone of dirt underneath.
generate_island :: proc(w: ^World) {
	R :: ISLAND_RADIUS
	for z in i32(-R - 6) ..= R + 6 {
		for x in i32(-R - 6) ..= R + 6 {
			// Wobbly rim so the island isn't a perfect circle.
			angle := math.atan2(f32(z), f32(x))
			edge := R + 3 * math.sin(angle * 3) + 2 * math.sin(angle * 7 + 1)
			dist := math.sqrt(f32(x * x + z * z))
			if dist > edge {
				continue
			}
			depth := 1 + i32((edge - dist) * 0.35) + i32(hash3(x, 0, z) % 2)
			for y in ISLAND_TOP - depth ..= ISLAND_TOP {
				world_set_block(w, x, y, z, Block.Grass if y == ISLAND_TOP else Block.Dirt)
			}
		}
	}
}

hash3 :: proc "contextless" (x, y, z: i32) -> u32 {
	h := u32(x) * 374761393 + u32(y) * 668265263 + u32(z) * 2147483647
	h = (h ~ (h >> 13)) * 1274126177
	return h ~ (h >> 16)
}
