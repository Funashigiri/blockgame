package main

CHUNK_SIZE   :: 16
CHUNK_SHIFT  :: 4
CHUNK_MASK   :: CHUNK_SIZE - 1
CHUNK_VOLUME :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

Block :: enum u8 {
	Air,
	Grass,
	Dirt,
	Core, // solid planet interior, never drawn
}

// x and z run across a planet face, y is the layer counted outward from the surface.
Chunk_Pos :: struct {
	face:    Cube_Face,
	x, y, z: i32,
}

Chunk :: struct {
	pos:    Chunk_Pos,
	anchor: [3]f64, // world position of the chunk's (0, 0, 0) corner; mesh vertices are relative to it
	blocks: [CHUNK_VOLUME]Block,
	mesh:   Chunk_Mesh,
}

World :: struct {
	chunks: map[Chunk_Pos]^Chunk,
}

block_index :: #force_inline proc "contextless" (x, y, z: i32) -> i32 {
	return (y * CHUNK_SIZE + z) * CHUNK_SIZE + x
}

world_new_chunk :: proc(w: ^World, pos: Chunk_Pos) -> ^Chunk {
	chunk := new(Chunk)
	chunk.pos = pos
	chunk.anchor = face_to_world(pos.face, f64(pos.x * CHUNK_SIZE), f64(pos.z * CHUNK_SIZE), f64(pos.y * CHUNK_SIZE))
	w.chunks[pos] = chunk
	return chunk
}

// x and z may be one block past the face edge; the lookup then continues on the neighbouring face.
// Arithmetic shift and mask act as floor division and modulo, so negative layers land in the right chunk.
world_get_block :: proc(w: ^World, face: Cube_Face, x, y, z: i32) -> Block {
	face, x, z := face, x, z
	if x < 0 || x >= FACE_BLOCKS || z < 0 || z >= FACE_BLOCKS {
		face, x, z = cross_face_edge(face, x, z)
	}
	chunk := w.chunks[Chunk_Pos{face, x >> CHUNK_SHIFT, y >> CHUNK_SHIFT, z >> CHUNK_SHIFT}]
	if chunk == nil {
		// Nothing generated here: deep down is solid planet, above the terrain is empty space.
		return Block.Core if y < 0 else Block.Air
	}
	return chunk.blocks[block_index(x & CHUNK_MASK, y & CHUNK_MASK, z & CHUNK_MASK)]
}

hash3 :: proc "contextless" (x, y, z: i32) -> u32 {
	h := u32(x) * 374761393 + u32(y) * 668265263 + u32(z) * 2147483647
	h = (h ~ (h >> 13)) * 1274126177
	return h ~ (h >> 16)
}
