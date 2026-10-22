package main

import "core:math"
import "core:math/linalg"

hash3 :: proc "contextless" (x, y, z: i32) -> u32 {
	h := u32(x) * 374761393 + u32(y) * 668265263 + u32(z) * 2147483647
	h = (h ~ (h >> 13)) * 1274126177
	return h ~ (h >> 16)
}

@(rodata)
GRADIENTS := [12][3]f64 {
	{1, 1, 0}, {-1, 1, 0}, {1, -1, 0}, {-1, -1, 0},
	{1, 0, 1}, {-1, 0, 1}, {1, 0, -1}, {-1, 0, -1},
	{0, 1, 1}, {0, -1, 1}, {0, 1, -1}, {0, -1, -1},
}

// Perlin gradient noise: smooth rises and dips in roughly -1..1, the same value for the same point every time.
gradient_noise_3d :: proc(p: [3]f64) -> f64 {
	cell := [3]f64{math.floor(p.x), math.floor(p.y), math.floor(p.z)}
	f := p - cell
	u := f * f * f * (f * (f * 6 - 15) + 10) // quintic fade, so cell borders never show as creases
	ix, iy, iz := i32(cell.x), i32(cell.y), i32(cell.z)
	g :: proc(ix, iy, iz: i32, d: [3]f64) -> f64 {
		return linalg.dot(GRADIENTS[hash3(ix, iy, iz) % 12], d)
	}
	n000 := g(ix, iy, iz, f)
	n100 := g(ix + 1, iy, iz, f - [3]f64{1, 0, 0})
	n010 := g(ix, iy + 1, iz, f - [3]f64{0, 1, 0})
	n110 := g(ix + 1, iy + 1, iz, f - [3]f64{1, 1, 0})
	n001 := g(ix, iy, iz + 1, f - [3]f64{0, 0, 1})
	n101 := g(ix + 1, iy, iz + 1, f - [3]f64{1, 0, 1})
	n011 := g(ix, iy + 1, iz + 1, f - [3]f64{0, 1, 1})
	n111 := g(ix + 1, iy + 1, iz + 1, f - [3]f64{1, 1, 1})
	x00 := math.lerp(n000, n100, u.x)
	x10 := math.lerp(n010, n110, u.x)
	x01 := math.lerp(n001, n101, u.x)
	x11 := math.lerp(n011, n111, u.x)
	return math.lerp(math.lerp(x00, x10, u.y), math.lerp(x01, x11, u.y), u.z)
}

// Layers of noise, each twice as detailed and half as strong: big shapes with smaller bumps on them.
// Different seeds sample far-apart regions, so they give unrelated patterns. Result is roughly -1..1.
fbm :: proc(p: [3]f64, octaves: int, seed: i32) -> f64 {
	p := p + [3]f64{31.7, -17.3, 47.1} * f64(seed)
	sum, amplitude, total := 0.0, 1.0, 0.0
	for _ in 0 ..< octaves {
		sum += gradient_noise_3d(p) * amplitude
		total += amplitude
		amplitude *= 0.5
		p *= 2.02 // not exactly 2, so the layers' lattices never line up
	}
	return sum / total
}
