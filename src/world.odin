package main

import "core:math/linalg"

CHUNK_SIZE   :: 16
CHUNK_SHIFT  :: 4
CHUNK_MASK   :: CHUNK_SIZE - 1
CHUNK_VOLUME :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

Block :: enum u8 {
	Air,
	Grass,
	Dirt,
	Stone,
	Core, // solid planet interior below the generated layers, never drawn
}

// x and z run across a planet face, y is the layer counted outward from the surface.
Chunk_Pos :: struct {
	face:    Cube_Face,
	x, y, z: i32,
}

Chunk :: struct {
	pos:    Chunk_Pos,
	anchor: [3]f64, // world position of the chunk's (0, 0, 0) corner; mesh vertices are relative to it
	center: [3]f64, // bounding sphere, for skipping chunks that can't be seen
	radius: f64,
	blocks: [CHUNK_VOLUME]Block,
	mesh:   Chunk_Mesh,
}

World :: struct {
	chunks:        map[Chunk_Pos]^Chunk,
	highest_point: [3]f64, // top of the tallest mountain
}

block_index :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return (y * CHUNK_SIZE + z) * CHUNK_SIZE + x
}

world_new_chunk :: proc(w: ^World, pos: Chunk_Pos) -> ^Chunk {
	chunk := new(Chunk)
	chunk.pos = pos
	base := [3]f64{f64(pos.x), f64(pos.y), f64(pos.z)} * CHUNK_SIZE
	chunk.anchor = face_to_world(pos.face, base.x, base.z, base.y)
	HALF :: CHUNK_SIZE / 2
	chunk.center = face_to_world(pos.face, base.x + HALF, base.z + HALF, base.y + HALF)
	// The chunk is bent to follow the ball, so measure to all 8 of its real corners.
	for i in 0 ..< 8 {
		corner := base + [3]f64{f64(i & 1), f64(i >> 1 & 1), f64(i >> 2 & 1)} * CHUNK_SIZE
		chunk.radius = max(chunk.radius, linalg.length(face_to_world(pos.face, corner.x, corner.z, corner.y) - chunk.center))
	}
	w.chunks[pos] = chunk
	return chunk
}

// x and z may be a few blocks past the face edge; the lookup then continues on the neighbouring face,
// or near a cube corner on the third face. Arithmetic shift and mask act as floor division and modulo,
// so negative layers land in the right chunk.
world_get_block :: proc(w: ^World, face: Cube_Face, x, y, z: i32) -> Block {
	face, x, z := face, x, z
	for _ in 0 ..< 2 {
		if x >= 0 && x < FACE_BLOCKS && z >= 0 && z < FACE_BLOCKS {
			break
		}
		face, x, z = cross_face_edge(face, x, z)
	}
	chunk := w.chunks[Chunk_Pos{face, x >> CHUNK_SHIFT, y >> CHUNK_SHIFT, z >> CHUNK_SHIFT}]
	if chunk == nil {
		// Nothing generated here: below the generated floor is solid planet, above the land is empty space.
		return Block.Core if y < 0 else Block.Air
	}
	return chunk.blocks[block_index(x & CHUNK_MASK, y & CHUNK_MASK, z & CHUNK_MASK)]
}
