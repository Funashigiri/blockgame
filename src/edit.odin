package main

import "core:math"
import "core:math/linalg"

REACH               :: 5.0  // blocks; a touch more than Minecraft's 4.5
RAY_STEP            :: 0.01 // the look ray is walked in steps this short, so it can't skip past a corner
EDIT_REPEAT_SECONDS :: 0.25 // holding a mouse button keeps breaking or placing at this pace

// As shown over the hotbar and on the F3 screen.
@(rodata)
BLOCK_NAMES := [Block]string {
	.Air    = "Воздух",
	.Grass  = "Трава",
	.Dirt   = "Земля",
	.Stone  = "Камень",
	.Sand   = "Песок",
	.Planks = "Доски",
	.Core   = "Ядро",
}

Ray_Hit :: struct {
	hit:    bool,
	block:  Block_Pos, // the solid block looked at
	before: Block_Pos, // the empty cell just in front of it, where a new block goes
}

// The block cell a world position falls in.
block_at_world :: proc(p: [3]f64) -> Block_Pos {
	face, g := world_to_face(p)
	x := clamp(i32(math.floor(g.x)), 0, FACE_BLOCKS - 1)
	z := clamp(i32(math.floor(g.z)), 0, FACE_BLOCKS - 1)
	return {face, x, i32(math.floor(g.y)), z}
}

block_center :: proc(pos: Block_Pos) -> [3]f64 {
	return face_to_world(pos.face, f64(pos.x) + 0.5, f64(pos.z) + 0.5, f64(pos.y) + 0.5)
}

// Walks the look ray in short steps in world space, so it follows the bent block grid and crosses
// face edges without special cases. Finds the first solid block within reach.
raycast :: proc(w: ^World, origin, dir: [3]f64) -> (result: Ray_Hit) {
	prev := block_at_world(origin)
	for t := 0.0; t <= REACH; t += RAY_STEP {
		cell := block_at_world(origin + dir * t)
		if cell == prev && t > 0 {
			continue
		}
		if block_is_solid(world_get_block(w, cell.face, cell.x, cell.y, cell.z)) {
			return {true, cell, prev}
		}
		prev = cell
	}
	return
}

// Breaks the block unless it is air or the core. Returns whether anything changed.
try_break :: proc(w: ^World, r: ^Renderer, pos: Block_Pos) -> bool {
	block := world_get_block(w, pos.face, pos.x, pos.y, pos.z)
	if block == .Air || block == .Core {
		return false
	}
	world_edit(w, r, pos, .Air)
	return true
}

// Places a block into an empty cell, unless the player is standing in it.
try_place :: proc(w: ^World, r: ^Renderer, p: Player, pos: Block_Pos, block: Block) -> bool {
	if world_get_block(w, pos.face, pos.x, pos.y, pos.z) != .Air || block_overlaps_player(pos, p) {
		return false
	}
	world_edit(w, r, pos, block)
	return true
}

// Compared in the player's own grid; a block or two away the two grids agree closely enough.
block_overlaps_player :: proc(pos: Block_Pos, p: Player) -> bool {
	face, feet := world_to_face(p.pos)
	c := world_to_face_on(face, block_center(pos))
	lo, hi := player_box(feet)
	for axis in 0 ..< 3 {
		if c[axis] + 0.5 <= lo[axis] || c[axis] - 0.5 >= hi[axis] {
			return false
		}
	}
	return true
}

// Changes one block and rebuilds the meshes that show it: its own chunk and any chunk across the sides
// it touches, generating those first if needed (digging down opens up rock that was never made).
world_edit :: proc(w: ^World, r: ^Renderer, pos: Block_Pos, block: Block) {
	world_set_block(w, pos, block)
	touched: [7]Chunk_Pos
	count := 0
	add :: proc(touched: ^[7]Chunk_Pos, count: ^int, c: Chunk_Pos) {
		for i in 0 ..< count^ {
			if touched[i] == c {
				return
			}
		}
		touched[count^] = c
		count^ += 1
	}
	add(&touched, &count, chunk_of(block_pos_on_planet(pos)))
	for side in Side {
		n := SIDE_NORMAL[side]
		neighbor := block_pos_on_planet({pos.face, pos.x + n.x, pos.y + n.y, pos.z + n.z})
		world_chunk_at(w, neighbor)
		add(&touched, &count, chunk_of(neighbor))
	}
	for i in 0 ..< count {
		remesh_chunk(w, r, w.chunks[touched[i]])
	}
}

// True on the click, then every EDIT_REPEAT_SECONDS while the button stays down.
button_fires :: proc(down: bool, was_down: ^bool, timer: ^f64, dt: f64) -> (fire: bool) {
	defer was_down^ = down
	switch {
	case !down:
		return false
	case !was_down^:
		timer^ = EDIT_REPEAT_SECONDS
		return true
	}
	timer^ -= dt
	if timer^ <= 0 {
		timer^ += EDIT_REPEAT_SECONDS
		return true
	}
	return false
}

// The 12 edges of a block, pushed out a hair so they never hide inside its faces; relative to the camera.
block_outline :: proc(pos: Block_Pos, camera_pos: [3]f64) -> (lines: [24][3]f32) {
	corners: [8][3]f64
	center := block_center(pos)
	for i in 0 ..< 8 {
		x, y, z := f64(i & 1), f64(i >> 1 & 1), f64(i >> 2 & 1)
		c := face_to_world(pos.face, f64(pos.x) + x, f64(pos.z) + z, f64(pos.y) + y)
		corners[i] = center + (c - center) * 1.004
	}
	n := 0
	bits := [3]int{1, 2, 4}
	for i in 0 ..< 8 {
		for bit in bits {
			if i & bit == 0 {
				lines[n] = ([3]f32)(corners[i] - camera_pos)
				lines[n + 1] = ([3]f32)(corners[i | bit] - camera_pos)
				n += 2
			}
		}
	}
	return
}

look_direction :: proc(cam: Camera) -> [3]f64 {
	return linalg.normalize(([3]f64)(camera_forward(cam)))
}
