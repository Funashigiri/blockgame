package main

import "core:math"
import "core:math/linalg"

// The planet is a cube puffed out into a ball. Each of its 6 faces is a square grid of
// FACE_BLOCKS x FACE_BLOCKS block columns; the radius is chosen so surface blocks are 1 m wide.
FACE_BLOCKS   :: 240
FACE_CHUNKS   :: FACE_BLOCKS / CHUNK_SIZE
PLANET_RADIUS :: f64(FACE_BLOCKS) * 2 / math.PI // about 153 m

SOIL_DEPTH :: 3 // dirt layers under the grass; stone below

// Land height in blocks above the base radius stays within these bounds.
MIN_HEIGHT :: -8
MAX_HEIGHT :: 48

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

// Which face a world position is over, and where in that face's block grid it is: x and z across the face
// (0..FACE_BLOCKS), y the layer above the base radius. The inverse of face_to_world.
world_to_face :: proc(p: [3]f64) -> (Cube_Face, [3]f64) {
	axis := 0
	for i in 1 ..< 3 {
		if abs(p[i]) > abs(p[axis]) {
			axis = i
		}
	}
	face := Cube_Face(axis * 2 + (0 if p[axis] > 0 else 1))
	return face, world_to_face_on(face, p)
}

// Like world_to_face, but in the grid of the given face even a little past its edge,
// so a move that crosses an edge can still be measured in one grid.
world_to_face_on :: proc(face: Cube_Face, p: [3]f64) -> [3]f64 {
	axes := FACE_AXES[face]
	n := linalg.dot(p, ([3]f64)(axes.normal))
	s := linalg.dot(p, ([3]f64)(axes.u)) / n
	t := linalg.dot(p, ([3]f64)(axes.v)) / n
	u := (math.atan(s) * 4 / math.PI + 1) * FACE_BLOCKS / 2
	v := (math.atan(t) * 4 / math.PI + 1) * FACE_BLOCKS / 2
	return {u, linalg.length(p) - PLANET_RADIUS, v}
}

// Moves a column that sits past a face edge onto the neighbouring face.
// Works on column centres in a doubled integer grid where the cube spans -N..N, so the fold is exact:
// the axis that overshot is pulled back onto the cube and becomes the new face's normal, and the old
// normal axis becomes an in-face axis, as many blocks in from the edge as the column was past it.
cross_face_edge :: proc(face: Cube_Face, x, z: i32) -> (Cube_Face, i32, i32) {
	N :: FACE_BLOCKS
	axes := FACE_AXES[face]
	p := axes.normal * N + axes.u * (2 * x + 1 - N) + axes.v * (2 * z + 1 - N)
	for i in 0 ..< 3 {
		if abs(p[i]) <= N {
			continue
		}
		overshoot := abs(p[i]) - N
		sign: i32 = 1 if p[i] > 0 else -1
		p[i] = sign * N
		for j in 0 ..< 3 {
			if axes.normal[j] != 0 {
				p[j] = axes.normal[j] * (N - overshoot)
			}
		}
		new_face := Cube_Face(i * 2 + (0 if sign > 0 else 1))
		new_axes := FACE_AXES[new_face]
		return new_face, (linalg.dot(p, new_axes.u) + N - 1) / 2, (linalg.dot(p, new_axes.v) + N - 1) / 2
	}
	return face, x, z
}

Column :: struct {
	height: i32,
	rocky:  bool, // bare stone on top instead of grass and dirt
}

// Rolling hills everywhere, plus mountain ranges where a slow noise allows them.
// Sampled at the column's real 3D position, so the land runs on across face edges without a break.
terrain_column :: proc(face: Cube_Face, x, z: i32) -> Column {
	p := face_to_world(face, f64(x) + 0.5, f64(z) + 0.5, 0)
	hills := fbm(p / 45, 4, 1) * 7
	ranges := math.smoothstep(0.1, 0.4, fbm(p / 90, 2, 2))
	ridge := 1 - abs(fbm(p / 30, 4, 3)) // sharp crests where the noise crosses zero
	mountains := ranges * ridge * ridge * 34
	height := clamp(i32(math.floor(2 + hills + mountains)), MIN_HEIGHT, MAX_HEIGHT)
	// High peaks are bare rock; a little noise keeps the rock line from being a perfect contour.
	rock_line := 24 + fbm(p / 12, 2, 4) * 6
	return {height, f64(height) >= rock_line}
}

column_block :: proc(c: Column, layer: i32) -> Block {
	switch {
	case layer > c.height:
		return .Air
	case c.rocky || layer < c.height - SOIL_DEPTH:
		return .Stone
	case layer == c.height:
		return .Grass
	}
	return .Dirt
}

generate_planet :: proc(w: ^World) {
	// Every column starts from the same floor, so a cliff above a low valley is never missing its lower part.
	floor_chunk := i32(MIN_HEIGHT - SOIL_DEPTH - 1) >> CHUNK_SHIFT
	peak := i32(min(i32))
	columns: [CHUNK_SIZE][CHUNK_SIZE]Column
	for face in Cube_Face {
		for cz in i32(0) ..< FACE_CHUNKS {
			for cx in i32(0) ..< FACE_CHUNKS {
				top := i32(min(i32))
				for z in i32(0) ..< CHUNK_SIZE {
					for x in i32(0) ..< CHUNK_SIZE {
						gx, gz := cx * CHUNK_SIZE + x, cz * CHUNK_SIZE + z
						c := terrain_column(face, gx, gz)
						columns[z][x] = c
						top = max(top, c.height)
						if c.height > peak {
							peak = c.height
							w.highest_point = face_to_world(face, f64(gx) + 0.5, f64(gz) + 0.5, f64(c.height + 1))
						}
					}
				}
				for cy := floor_chunk; cy <= top >> CHUNK_SHIFT; cy += 1 {
					chunk := world_new_chunk(w, Chunk_Pos{face, cx, cy, cz})
					for y in i32(0) ..< CHUNK_SIZE {
						for z in i32(0) ..< CHUNK_SIZE {
							for x in i32(0) ..< CHUNK_SIZE {
								chunk.blocks[block_index(x, y, z)] = column_block(columns[z][x], cy * CHUNK_SIZE + y)
							}
						}
					}
				}
			}
		}
	}
}
