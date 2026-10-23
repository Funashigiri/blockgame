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
	Sand,
	Planks,
	Core, // molten planet core under the deepest rock; cannot be broken
}

// x and z run across a planet face, y is the layer counted outward from the surface.
Chunk_Pos :: struct {
	face:    Cube_Face,
	x, y, z: i32,
}

// One block: x and z across a face, y the layer.
Block_Pos :: struct {
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

// Arithmetic shift acts as floor division, so negative layers land in the right chunk.
chunk_of :: proc(pos: Block_Pos) -> Chunk_Pos {
	return {pos.face, pos.x >> CHUNK_SHIFT, pos.y >> CHUNK_SHIFT, pos.z >> CHUNK_SHIFT}
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

// x and z may be a few blocks past the face edge; this moves the position onto the neighbouring face,
// or near a cube corner onto the third face.
block_pos_on_planet :: proc(pos: Block_Pos) -> Block_Pos {
	pos := pos
	for _ in 0 ..< 2 {
		if pos.x >= 0 && pos.x < FACE_BLOCKS && pos.z >= 0 && pos.z < FACE_BLOCKS {
			break
		}
		pos.face, pos.x, pos.z = cross_face_edge(pos.face, pos.x, pos.z)
	}
	return pos
}

world_get_block :: proc(w: ^World, face: Cube_Face, x, y, z: i32) -> Block {
	pos := block_pos_on_planet({face, x, y, z})
	chunk := w.chunks[chunk_of(pos)]
	if chunk == nil {
		// Not generated: chunks are made from the floor up to the land, so below that it is all rock
		// down to the core, and above it is empty space.
		if y < 0 {
			return Block.Core if y < CORE_TOP else Block.Stone
		}
		return .Air
	}
	return chunk.blocks[block_index(pos.x & CHUNK_MASK, pos.y & CHUNK_MASK, pos.z & CHUNK_MASK)]
}

// The chunk holding a block, generated first if it doesn't exist yet.
world_chunk_at :: proc(w: ^World, pos: Block_Pos) -> ^Chunk {
	pos := block_pos_on_planet(pos)
	chunk := w.chunks[chunk_of(pos)]
	if chunk == nil {
		chunk = world_generate_chunk(w, chunk_of(pos))
	}
	return chunk
}

world_set_block :: proc(w: ^World, pos: Block_Pos, block: Block) {
	pos := block_pos_on_planet(pos)
	chunk := world_chunk_at(w, pos)
	chunk.blocks[block_index(pos.x & CHUNK_MASK, pos.y & CHUNK_MASK, pos.z & CHUNK_MASK)] = block
}
