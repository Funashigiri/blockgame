package main

import "core:math"
import "core:math/linalg"

PITCH_LIMIT :: 1.55 // just under 90 degrees, so looking straight up or down never flips the view

// "Up" is always away from the planet centre, so the horizon stays level wherever you fly.
Camera :: struct {
	pos:     [3]f64, // relative to the planet centre
	heading: [3]f32, // forward along the ground, kept tangent to the planet
	pitch:   f32,    // radians; positive looks up
}

camera_up :: proc(cam: Camera) -> [3]f32 {
	return ([3]f32)(linalg.normalize(cam.pos))
}

camera_right :: proc(cam: Camera) -> [3]f32 {
	return linalg.cross(cam.heading, camera_up(cam))
}

camera_forward :: proc(cam: Camera) -> [3]f32 {
	return cam.heading * math.cos(cam.pitch) + camera_up(cam) * math.sin(cam.pitch)
}

// Tilts the heading back onto the ground plane after a move, so it keeps pointing where it did
// while "up" follows the curve of the planet.
camera_align :: proc(cam: ^Camera) {
	up := camera_up(cam^)
	h := cam.heading - up * linalg.dot(cam.heading, up)
	if linalg.length(h) < 1e-4 {
		// Heading lined up with "up": any direction along the ground will do.
		h = linalg.cross(up, [3]f32{0, 0, 1} if abs(up.z) < 0.9 else [3]f32{1, 0, 0})
	}
	cam.heading = linalg.normalize(h)
}

// Positive angle turns right.
camera_turn :: proc(cam: ^Camera, angle: f32) {
	cam.heading = linalg.normalize(cam.heading * math.cos(angle) + camera_right(cam^) * math.sin(angle))
}

camera_look_at :: proc(cam: ^Camera, target: [3]f64) {
	dir := ([3]f32)(linalg.normalize(target - cam.pos))
	cam.pitch = clamp(math.asin(clamp(linalg.dot(dir, camera_up(cam^)), -1, 1)), -PITCH_LIMIT, PITCH_LIMIT)
	cam.heading = dir
	camera_align(cam)
}

// Rotation only: the world is drawn relative to the camera, which keeps precision far from the origin.
camera_view :: proc(cam: Camera) -> matrix[4, 4]f32 {
	return linalg.matrix4_look_at_f32({0, 0, 0}, camera_forward(cam), camera_up(cam))
}
