package main

import "core:math"
import "core:math/linalg"

// Sizes are in blocks and speeds in blocks per second, the same as Minecraft, so the world feels familiar.
PLAYER_HALF_WIDTH :: 0.3
PLAYER_HEIGHT     :: 1.8
EYE_HEIGHT        :: 1.62
WALK_SPEED        :: 4.3
SPRINT_SPEED      :: 5.6
JUMP_HEIGHT       :: 1.25 // just clears one block
GROUND_ACCEL      :: 40.0 // how quickly you reach walking speed or come to a stop
AIR_ACCEL         :: 10.0 // a little steering while in the air
FLY_ACCEL         :: 40.0

// This planet stands in for the future Earth, so it pulls like the Earth does.
GRAVITY        :: 9.81
MAX_FALL_SPEED :: 55.0 // terminal velocity in air

PHYSICS_STEP :: 1.0 / 120 // longest physics step; a frame is cut into as many as it needs
SKIN         :: 1e-6      // hair of space kept from walls, so touching one never counts as being inside it
MAX_LIFT     :: 0.5       // how far the player may be lifted out of ground it has sunk into

Player :: struct {
	pos:       [3]f64, // feet, relative to the planet centre
	vel:       [3]f64, // metres per second
	on_ground: bool,
	flying:    bool,
}

Input :: struct {
	move:       [2]f32, // x right, y forward, each -1..1
	jump:       bool,   // held: jump when walking, rise when flying
	descend:    bool,   // held: sink when flying
	sprint:     bool,
	toggle_fly: bool,   // jump was double-tapped this frame
}

player_eye :: proc(p: Player) -> [3]f64 {
	return p.pos + linalg.normalize(p.pos) * EYE_HEIGHT
}

// heading is where the camera faces along the ground.
player_update :: proc(w: ^World, p: ^Player, heading: [3]f32, input: Input, dt: f64) {
	if input.toggle_fly {
		p.flying = !p.flying
		p.vel = {}
	}
	steps := max(1, int(math.ceil(dt / PHYSICS_STEP)))
	for _ in 0 ..< steps {
		player_step(w, p, ([3]f64)(heading), input, dt / f64(steps))
	}
}

player_step :: proc(w: ^World, p: ^Player, heading: [3]f64, input: Input, h: f64) {
	// Gravity, "up" and the ground plane all follow the planet centre.
	up := linalg.normalize(p.pos)
	forward := linalg.normalize(heading - up * linalg.dot(heading, up))
	right := linalg.cross(forward, up)
	wish := forward * f64(input.move.y) + right * f64(input.move.x)
	if linalg.length(wish) > 1 {
		wish = linalg.normalize(wish)
	}

	if p.flying {
		speed: f64 = FLY_SPEED
		if input.sprint {
			speed *= SPRINT_MULTIPLIER
		}
		rise: f64 = 0
		if input.jump {rise += 1}
		if input.descend {rise -= 1}
		p.vel = move_toward(p.vel, (wish + up * rise) * speed, FLY_ACCEL * h)
	} else {
		speed: f64 = SPRINT_SPEED if input.sprint else WALK_SPEED
		accel: f64 = GROUND_ACCEL if p.on_ground else AIR_ACCEL
		vertical := linalg.dot(p.vel, up)
		horizontal := move_toward(p.vel - up * vertical, wish * speed, accel * h)
		vertical = max(vertical - GRAVITY * h, -MAX_FALL_SPEED)
		if p.on_ground && input.jump {
			vertical = math.sqrt(2 * GRAVITY * JUMP_HEIGHT)
		}
		p.vel = horizontal + up * vertical
	}

	move_and_collide(w, p, p.vel * h)
	// Touching down ends a flight, like in Minecraft.
	if p.flying && p.on_ground {
		p.flying = false
	}
}

move_toward :: proc(v, target: [3]f64, max_step: f64) -> [3]f64 {
	diff := target - v
	dist := linalg.length(diff)
	if dist <= max_step {
		return target
	}
	return v + diff * (max_step / dist)
}

// Collisions happen in the block grid of the face the player stands over, where every block is a plain
// unit cube. The move goes one grid axis at a time, up/down first like Minecraft, stopping at solid
// blocks and cancelling the speed that pushed into them.
move_and_collide :: proc(w: ^World, p: ^Player, delta_world: [3]f64) {
	face, start := world_to_face(p.pos)
	delta := world_to_face_on(face, p.pos + delta_world) - start
	pos := push_out_of_ground(w, face, start)
	p.on_ground = false
	order := [3]int{1, 0, 2}
	for axis in order {
		if delta[axis] == 0 {
			continue
		}
		moved, hit := sweep_axis(w, face, pos, axis, delta[axis])
		pos[axis] += moved
		if hit {
			e := grid_axis_direction(face, pos, axis)
			p.vel -= e * linalg.dot(p.vel, e)
			if axis == 1 && delta[axis] < 0 {
				p.on_ground = true
			}
		}
	}
	p.pos = face_to_world(face, pos.x, pos.z, pos.y)
}

// The player's box in grid coordinates: feet in the middle of its bottom.
player_box :: proc(pos: [3]f64) -> (lo, hi: [3]f64) {
	return pos - [3]f64{PLAYER_HALF_WIDTH, 0, PLAYER_HALF_WIDTH}, pos + [3]f64{PLAYER_HALF_WIDTH, PLAYER_HEIGHT, PLAYER_HALF_WIDTH}
}

cell_floor :: proc(p: [3]f64) -> [3]i32 {
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

block_is_solid :: proc(b: Block) -> bool {
	return b != .Air
}

// How far the box can move along one grid axis before it meets a solid block.
// Blocks the box already overlaps are ignored, so it can always move back out of them.
sweep_axis :: proc(w: ^World, face: Cube_Face, pos: [3]f64, axis: int, amount: f64) -> (moved: f64, hit: bool) {
	lo, hi := player_box(pos)
	reach_lo, reach_hi := lo, hi
	if amount > 0 {
		reach_hi[axis] += amount
	} else {
		reach_lo[axis] += amount
	}
	moved = amount
	first, last := cell_floor(reach_lo + SKIN), cell_floor(reach_hi - SKIN)
	for y in first.y ..= last.y {
		for z in first.z ..= last.z {
			for x in first.x ..= last.x {
				if !block_is_solid(world_get_block(w, face, x, y, z)) {
					continue
				}
				near := f64([3]i32{x, y, z}[axis])
				if amount > 0 && near >= hi[axis] - SKIN {
					if allowed := near - hi[axis] - SKIN; allowed < moved {
						moved, hit = max(allowed, 0), true
					}
				} else if amount < 0 && near + 1 <= lo[axis] + SKIN {
					if allowed := near + 1 - lo[axis] + SKIN; allowed > moved {
						moved, hit = min(allowed, 0), true
					}
				}
			}
		}
	}
	return
}

// Right at a face edge two block grids meet at a slight angle, so the box can end up a little inside
// the ground. Lift it back on top, as long as that is a small step.
push_out_of_ground :: proc(w: ^World, face: Cube_Face, pos: [3]f64) -> [3]f64 {
	lo, hi := player_box(pos)
	first, last := cell_floor(lo + SKIN), cell_floor(hi - SKIN)
	lift := 0.0
	for y in first.y ..= last.y {
		for z in first.z ..= last.z {
			for x in first.x ..= last.x {
				if !block_is_solid(world_get_block(w, face, x, y, z)) {
					continue
				}
				if sink := f64(y + 1) - lo.y; sink <= MAX_LIFT {
					lift = max(lift, sink + SKIN)
				}
			}
		}
	}
	return pos + [3]f64{0, lift, 0}
}

// World direction of one grid axis at a point; grid axes bend with the ball, so it is measured locally.
grid_axis_direction :: proc(face: Cube_Face, pos: [3]f64, axis: int) -> [3]f64 {
	step: [3]f64
	step[axis] = 0.01
	a := face_to_world(face, pos.x, pos.z, pos.y)
	b := face_to_world(face, pos.x + step.x, pos.z + step.z, pos.y + step.y)
	return linalg.normalize(b - a)
}

// True if the player's box (shrunk a little, to ignore touching) overlaps any solid block.
player_inside_block :: proc(w: ^World, p: Player) -> bool {
	face, pos := world_to_face(p.pos)
	lo, hi := player_box(pos)
	first, last := cell_floor(lo + 0.01), cell_floor(hi - 0.01)
	for y in first.y ..= last.y {
		for z in first.z ..= last.z {
			for x in first.x ..= last.x {
				if block_is_solid(world_get_block(w, face, x, y, z)) {
					return true
				}
			}
		}
	}
	return false
}
