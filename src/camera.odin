package main

import "core:math"
import "core:math/linalg"

PITCH_LIMIT :: 1.55 // just under 90 degrees, so looking straight up or down never flips the view

Camera :: struct {
	pos:   [3]f32,
	yaw:   f32, // radians; 0 looks toward -Z, growing turns right
	pitch: f32, // radians; positive looks up
}

camera_forward :: proc(cam: Camera) -> [3]f32 {
	cos_pitch := math.cos(cam.pitch)
	return {math.sin(cam.yaw) * cos_pitch, math.sin(cam.pitch), -math.cos(cam.yaw) * cos_pitch}
}

camera_view :: proc(cam: Camera) -> matrix[4, 4]f32 {
	return linalg.matrix4_look_at_f32(cam.pos, cam.pos + camera_forward(cam), {0, 1, 0})
}

camera_look_at :: proc(cam: ^Camera, target: [3]f32) {
	dir := target - cam.pos
	cam.yaw = math.atan2(dir.x, -dir.z)
	cam.pitch = math.atan2(dir.y, linalg.length(dir.xz))
}
