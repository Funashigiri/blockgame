package main

import "core:math"
import "core:math/linalg"

// The planet is a cube puffed out into a ball. Each of its 6 faces is a square grid of
// FACE_BLOCKS x FACE_BLOCKS block columns; the radius is chosen so surface blocks are 1 m wide.
FACE_BLOCKS   :: 240
FACE_CHUNKS   :: FACE_BLOCKS / CHUNK_SIZE
PLANET_RADIUS :: f64(FACE_BLOCKS) * 2 / math.PI // about 153 m

SOIL_DEPTH :: 3 // dirt layers under the grass; below them is the solid core

Cube_Face :: enum i32 {
	PX,
	NX,
	PY,
	NY,
	PZ,
	NZ,
}

Face_Axes :: struct {
	normal, u, v: [3]i32,
}

// u x normal = v keeps every face's (u, up, v) grid right-handed like (x, y, z),
// so block faces wind the same way on all six faces.
@(rodata)
FACE_AXES := [Cube_Face]Face_Axes {
	.PX = {normal = {+1, 0, 0}, u = {0, 1, 0}, v = {0, 0, -1}},
	.NX = {normal = {-1, 0, 0}, u = {0, 1, 0}, v = {0, 0, +1}},
	.PY = {normal = {0, +1, 0}, u = {0, 0, 1}, v = {-1, 0, 0}},
	.NY = {normal = {0, -1, 0}, u = {0, 0, 1}, v = {+1, 0, 0}},
	.PZ = {normal = {0, 0, +1}, u = {1, 0, 0}, v = {0, -1, 0}},
	.NZ = {normal = {0, 0, -1}, u = {1, 0, 0}, v = {0, +1, 0}},
}

// World position (planet centre at the origin) of a point in a face's block grid:
// u and v run 0..FACE_BLOCKS across the face, layer is the height above the surface in blocks.
// The equal-angle mapping keeps blocks close to square all the way to the face edges.
face_to_world :: proc(face: Cube_Face, u, v, layer: f64) -> [3]f64 {
	axes := FACE_AXES[face]
	s := math.tan((2 * u / FACE_BLOCKS - 1) * math.PI / 4)
	t := math.tan((2 * v / FACE_BLOCKS - 1) * math.PI / 4)
	dir := ([3]f64)(axes.normal) + ([3]f64)(axes.u) * s + ([3]f64)(axes.v) * t
	return linalg.normalize(dir) * (PLANET_RADIUS + layer)
}

// Moves a column that sits one block past a face edge onto the neighbouring face.
// Works on column centres in a doubled integer grid where the cube spans -N..N, so the fold is exact:
// the axis that overshot is pulled back onto the cube and becomes the new face's normal, and the old
// normal axis becomes an in-face axis, one block in from the edge.
cross_face_edge :: proc(face: Cube_Face, x, z: i32) -> (Cube_Face, i32, i32) {
	N :: FACE_BLOCKS
	axes := FACE_AXES[face]
	p := axes.normal * N + axes.u * (2 * x + 1 - N) + axes.v * (2 * z + 1 - N)
	for i in 0 ..< 3 {
		if abs(p[i]) <= N {
			continue
		}
		sign: i32 = 1 if p[i] > 0 else -1
		p[i] = sign * N
		for j in 0 ..< 3 {
			if axes.normal[j] != 0 {
				p[j] = axes.normal[j] * (N - 1)
			}
		}
		new_face := Cube_Face(i * 2 + (0 if sign > 0 else 1))
		new_axes := FACE_AXES[new_face]
		return new_face, (linalg.dot(p, new_axes.u) + N - 1) / 2, (linalg.dot(p, new_axes.v) + N - 1) / 2
	}
	return face, x, z
}

generate_planet :: proc(w: ^World) {
	heights: [CHUNK_SIZE][CHUNK_SIZE]i32
	for face in Cube_Face {
		for cz in i32(0) ..< FACE_CHUNKS {
			for cx in i32(0) ..< FACE_CHUNKS {
				top := min(i32)
				for z in i32(0) ..< CHUNK_SIZE {
					for x in i32(0) ..< CHUNK_SIZE {
						h := surface_height(face, cx * CHUNK_SIZE + x, cz * CHUNK_SIZE + z)
						heights[z][x] = h
						top = max(top, h)
					}
				}
				// From the chunk holding the deepest dirt up to the one holding the highest grass.
				for cy := i32(-SOIL_DEPTH - 1) >> CHUNK_SHIFT; cy <= top >> CHUNK_SHIFT; cy += 1 {
					chunk := world_new_chunk(w, Chunk_Pos{face, cx, cy, cz})
					for y in i32(0) ..< CHUNK_SIZE {
						layer := cy * CHUNK_SIZE + y
						for z in i32(0) ..< CHUNK_SIZE {
							for x in i32(0) ..< CHUNK_SIZE {
								h := heights[z][x]
								block := Block.Air
								switch {
								case layer == h:
									block = .Grass
								case layer < h - SOIL_DEPTH:
									block = .Core
								case layer < h:
									block = .Dirt
								}
								chunk.blocks[block_index(x, y, z)] = block
							}
						}
					}
				}
			}
		}
	}
}

// Low mounds a block or two high, so the blocks show on an otherwise smooth ball.
// The noise is sampled in 3D at the column's real position, so it runs on across face edges without a break.
surface_height :: proc(face: Cube_Face, x, z: i32) -> i32 {
	p := face_to_world(face, f64(x) + 0.5, f64(z) + 0.5, 0)
	n := value_noise_3d(p / 10)
	return i32(clamp((n - 0.5) * 6, 0, 2))
}

// Smoothly blended random values on an integer lattice, in 0..1.
value_noise_3d :: proc(p: [3]f64) -> f64 {
	cell := [3]f64{math.floor(p.x), math.floor(p.y), math.floor(p.z)}
	f := p - cell
	f = f * f * (3 - 2 * f) // smoothstep, so lattice lines don't show as creases
	ix, iy, iz := i32(cell.x), i32(cell.y), i32(cell.z)
	corner :: proc(x, y, z: i32) -> f64 {
		return f64(hash3(x, y, z) & 0xFFFF) / 0xFFFF
	}
	x00 := math.lerp(corner(ix, iy, iz), corner(ix + 1, iy, iz), f.x)
	x10 := math.lerp(corner(ix, iy + 1, iz), corner(ix + 1, iy + 1, iz), f.x)
	x01 := math.lerp(corner(ix, iy, iz + 1), corner(ix + 1, iy, iz + 1), f.x)
	x11 := math.lerp(corner(ix, iy + 1, iz + 1), corner(ix + 1, iy + 1, iz + 1), f.x)
	return math.lerp(math.lerp(x00, x10, f.y), math.lerp(x01, x11, f.y), f.z)
}
