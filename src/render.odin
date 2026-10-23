package main

import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"

// Enough for the worst case chunk (a 3D checkerboard) while indices still fit in u16.
MAX_QUADS_PER_CHUNK :: 16384

STAR_COUNT :: 4000

Chunk_Mesh :: struct {
	vao, vbo:    u32,
	index_count: i32,
}

Renderer :: struct {
	program:          u32,
	u_view_proj:      i32,
	u_chunk_offset:   i32,
	texture:          u32,
	quad_ebo:         u32,
	star_program:     u32,
	u_star_view_proj: i32,
	star_vao:         u32,
	// Plain-coloured lines and shapes drawn over the world: the block outline and the crosshair.
	overlay_program:  u32,
	u_overlay_matrix: i32,
	u_overlay_color:  i32,
	overlay_vao:      u32,
	overlay_vbo:      u32,
	scratch:          [dynamic]Vertex, // reused while rebuilding a chunk mesh
}

OVERLAY_VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec3 a_pos;
uniform mat4 u_matrix;
void main() {
	gl_Position = u_matrix * vec4(a_pos, 1.0);
}
`

OVERLAY_FRAGMENT_SHADER :: `#version 330 core
uniform vec4 u_color;
out vec4 frag_color;
void main() {
	frag_color = u_color;
}
`

OVERLAY_MAX_VERTICES :: 32

CROSSHAIR_ARM       :: 9 // pixels from the centre to the end of each arm
CROSSHAIR_THICKNESS :: 1 // half the line thickness, in pixels

VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec4 a_info; // u, v, texture layer, brightness 0..255

uniform mat4 u_view_proj;
uniform vec3 u_chunk_offset; // chunk anchor relative to the camera

out vec2 v_uv;
flat out float v_layer;
out float v_shade;

void main() {
	gl_Position = u_view_proj * vec4(a_pos + u_chunk_offset, 1.0);
	v_uv = a_info.xy;
	v_layer = a_info.z;
	v_shade = a_info.w / 255.0;
}
`

FRAGMENT_SHADER :: `#version 330 core
in vec2 v_uv;
flat in float v_layer;
in float v_shade;

uniform sampler2DArray u_texture;

out vec4 frag_color;

void main() {
	vec3 color = texture(u_texture, vec3(v_uv, v_layer)).rgb;
	frag_color = vec4(color * v_shade, 1.0);
}
`

STAR_VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec3 a_dir;
layout(location = 1) in vec2 a_size_brightness;

uniform mat4 u_view_proj;

out float v_brightness;

void main() {
	// w = 0 puts the star infinitely far away, so it never moves as the camera flies.
	gl_Position = (u_view_proj * vec4(a_dir, 0.0)).xyww;
	gl_PointSize = a_size_brightness.x;
	v_brightness = a_size_brightness.y;
}
`

STAR_FRAGMENT_SHADER :: `#version 330 core
in float v_brightness;
out vec4 frag_color;

void main() {
	frag_color = vec4(vec3(v_brightness), 1.0);
}
`

Star_Vertex :: struct {
	dir:             [3]f32,
	size_brightness: [2]f32,
}

renderer_init :: proc(r: ^Renderer) -> bool {
	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		return false
	}
	r.program = program
	r.u_view_proj = gl.GetUniformLocation(program, "u_view_proj")
	r.u_chunk_offset = gl.GetUniformLocation(program, "u_chunk_offset")

	star_program, star_ok := gl.load_shaders_source(STAR_VERTEX_SHADER, STAR_FRAGMENT_SHADER)
	if !star_ok {
		return false
	}
	r.star_program = star_program
	r.u_star_view_proj = gl.GetUniformLocation(star_program, "u_view_proj")

	overlay_program, overlay_ok := gl.load_shaders_source(OVERLAY_VERTEX_SHADER, OVERLAY_FRAGMENT_SHADER)
	if !overlay_ok {
		return false
	}
	r.overlay_program = overlay_program
	r.u_overlay_matrix = gl.GetUniformLocation(overlay_program, "u_matrix")
	r.u_overlay_color = gl.GetUniformLocation(overlay_program, "u_color")
	gl.GenVertexArrays(1, &r.overlay_vao)
	gl.GenBuffers(1, &r.overlay_vbo)
	gl.BindVertexArray(r.overlay_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.overlay_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, OVERLAY_MAX_VERTICES * size_of([3]f32), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of([3]f32), 0)
	gl.BindVertexArray(0)

	// One index buffer shared by every chunk: quad i is vertices 4i..4i+3 as two triangles.
	indices := make([]u16, MAX_QUADS_PER_CHUNK * 6, context.temp_allocator)
	for q in 0 ..< MAX_QUADS_PER_CHUNK {
		v := u16(q * 4)
		copy(indices[q * 6:], []u16{v, v + 1, v + 2, v, v + 2, v + 3})
	}
	// Uploaded through ARRAY_BUFFER because no VAO is bound yet; each chunk VAO binds it as its index buffer.
	gl.GenBuffers(1, &r.quad_ebo)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.quad_ebo)
	gl.BufferData(gl.ARRAY_BUFFER, len(indices) * size_of(u16), raw_data(indices), gl.STATIC_DRAW)

	// A texture array keeps each 16x16 block texture in its own layer, so mipmaps never bleed between them.
	pixels := generate_textures(context.temp_allocator)
	gl.GenTextures(1, &r.texture)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, r.texture)
	gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA8, TEX_SIZE, TEX_SIZE, len(Tex), 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.GenerateMipmap(gl.TEXTURE_2D_ARRAY)
	// NEAREST up close keeps the crisp pixels; mipmaps far away stop the grass from shimmering.
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.REPEAT)

	stars_init(r)

	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.PROGRAM_POINT_SIZE)
	return true
}

// Random stars on the sky sphere: many faint ones, a few big bright ones.
stars_init :: proc(r: ^Renderer) {
	stars := make([]Star_Vertex, STAR_COUNT, context.temp_allocator)
	random :: proc(i, channel: i32) -> f32 {
		return f32(hash3(i, channel, 9001) & 0xFFFF) / 0xFFFF
	}
	for &star, i in stars {
		z := random(i32(i), 0) * 2 - 1
		angle := random(i32(i), 1) * 2 * math.PI
		ring := math.sqrt(1 - z * z)
		b := random(i32(i), 2)
		star.dir = {ring * math.cos(angle), ring * math.sin(angle), z}
		star.size_brightness = {1 + 1.5 * math.pow(b, 8), 0.25 + 0.75 * b * b * b}
	}
	vbo: u32
	gl.GenVertexArrays(1, &r.star_vao)
	gl.GenBuffers(1, &vbo)
	gl.BindVertexArray(r.star_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(stars) * size_of(Star_Vertex), raw_data(stars), gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, size_of(Star_Vertex), offset_of(Star_Vertex, dir))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Star_Vertex), offset_of(Star_Vertex, size_brightness))
	gl.BindVertexArray(0)
}

upload_chunk_mesh :: proc(r: ^Renderer, mesh: ^Chunk_Mesh, vertices: []Vertex) {
	assert(len(vertices) / 4 <= MAX_QUADS_PER_CHUNK)
	if mesh.vao == 0 {
		gl.GenVertexArrays(1, &mesh.vao)
		gl.GenBuffers(1, &mesh.vbo)
		gl.BindVertexArray(mesh.vao)
		gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo)
		gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.quad_ebo)
		stride := i32(size_of(Vertex))
		gl.EnableVertexAttribArray(0)
		gl.VertexAttribPointer(0, 3, gl.FLOAT, false, stride, offset_of(Vertex, pos))
		gl.EnableVertexAttribArray(1)
		gl.VertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, false, stride, offset_of(Vertex, info))
		gl.BindVertexArray(0)
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(vertices) * size_of(Vertex), raw_data(vertices), gl.STATIC_DRAW)
	mesh.index_count = i32(len(vertices) / 4 * 6)
}

remesh_chunk :: proc(w: ^World, r: ^Renderer, chunk: ^Chunk) {
	build_chunk_mesh(w, chunk, &r.scratch)
	upload_chunk_mesh(r, &chunk.mesh, r.scratch[:])
}

// Builds and uploads every chunk; returns the number of block sides and of chunks that have any.
mesh_world :: proc(w: ^World, r: ^Renderer) -> (sides, meshed_chunks: int) {
	for _, chunk in w.chunks {
		remesh_chunk(w, r, chunk)
		sides += len(r.scratch) / 4
		if len(r.scratch) > 0 {
			meshed_chunks += 1
		}
	}
	return
}

// Build with -define:NO_CULLING=true to draw everything, e.g. to check culling never hides anything visible.
NO_CULLING :: #config(NO_CULLING, false)

// The planet is solid at least this far out from its centre, so it hides whatever is behind it.
OCCLUDER_RADIUS :: PLANET_RADIUS + MIN_HEIGHT

// Planes of the camera's view pyramid, pointing inward (Gribb-Hartmann extraction from the matrix).
frustum_planes :: proc(m: matrix[4, 4]f32) -> (planes: [6][4]f32) {
	row :: proc(m: matrix[4, 4]f32, i: int) -> [4]f32 {
		return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}
	}
	r0, r1, r2, r3 := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	planes = {r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 + r2, r3 - r2}
	for &p in planes {
		p /= linalg.length(p.xyz)
	}
	return
}

sphere_in_frustum :: proc(planes: ^[6][4]f32, center: [3]f32, radius: f32) -> bool {
	for p in planes {
		if linalg.dot(p.xyz, center) + p.w < -radius {
			return false
		}
	}
	return true
}

// Two points can see each other past a ball when the angle between them, seen from the ball's centre,
// is less than how far each of them sees around it. Errs on the side of drawing.
beyond_horizon :: proc(camera_pos, center: [3]f64, radius: f64) -> bool {
	camera_dist := linalg.length(camera_pos)
	dist := linalg.length(center)
	top := dist + radius
	if camera_dist <= OCCLUDER_RADIUS || dist <= radius || top <= OCCLUDER_RADIUS {
		return false
	}
	angle := math.acos(clamp(linalg.dot(camera_pos, center) / (camera_dist * dist), -1, 1))
	reach := math.acos(OCCLUDER_RADIUS / camera_dist) + math.acos(OCCLUDER_RADIUS / top) + math.asin(radius / dist)
	return angle > reach
}

// view_proj must be rotation-only: every chunk is placed relative to the camera, so numbers stay small
// and precise however far from the planet centre the camera is.
// Skips chunks outside the view and chunks hidden behind the planet; returns how many were drawn.
renderer_draw :: proc(r: ^Renderer, w: ^World, view_proj: matrix[4, 4]f32, camera_pos: [3]f64) -> (drawn: int) {
	view_proj := view_proj

	// Stars first and without depth, so everything else simply draws over them.
	gl.Disable(gl.DEPTH_TEST)
	gl.UseProgram(r.star_program)
	gl.UniformMatrix4fv(r.u_star_view_proj, 1, false, &view_proj[0, 0])
	gl.BindVertexArray(r.star_vao)
	gl.DrawArrays(gl.POINTS, 0, STAR_COUNT)

	gl.Enable(gl.DEPTH_TEST)
	gl.UseProgram(r.program)
	gl.UniformMatrix4fv(r.u_view_proj, 1, false, &view_proj[0, 0])
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, r.texture)
	planes := frustum_planes(view_proj)
	for _, chunk in w.chunks {
		if chunk.mesh.index_count == 0 {
			continue
		}
		when !NO_CULLING {
			if !sphere_in_frustum(&planes, ([3]f32)(chunk.center - camera_pos), f32(chunk.radius)) {
				continue
			}
			if beyond_horizon(camera_pos, chunk.center, chunk.radius) {
				continue
			}
		}
		offset := ([3]f32)(chunk.anchor - camera_pos)
		gl.Uniform3f(r.u_chunk_offset, offset.x, offset.y, offset.z)
		gl.BindVertexArray(chunk.mesh.vao)
		gl.DrawElements(gl.TRIANGLES, chunk.mesh.index_count, gl.UNSIGNED_SHORT, nil)
		drawn += 1
	}
	return
}

// Thin dark edges around the block being looked at, like Minecraft. They are depth-tested,
// so other blocks in front still cover them.
renderer_draw_outline :: proc(r: ^Renderer, view_proj: matrix[4, 4]f32, pos: Block_Pos, camera_pos: [3]f64) {
	view_proj := view_proj
	lines := block_outline(pos, camera_pos)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.UseProgram(r.overlay_program)
	gl.UniformMatrix4fv(r.u_overlay_matrix, 1, false, &view_proj[0, 0])
	gl.Uniform4f(r.u_overlay_color, 0, 0, 0, 0.9)
	gl.BindVertexArray(r.overlay_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.overlay_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(lines) * size_of([3]f32), &lines[0])
	gl.DrawArrays(gl.LINES, 0, i32(len(lines)))
	gl.Disable(gl.BLEND)
}

// A small plus in the middle of the screen that inverts whatever is behind it, so it shows on any colour.
renderer_draw_crosshair :: proc(r: ^Renderer, width, height: i32) {
	px := [2]f32{2 / f32(width), 2 / f32(height)} // one pixel in screen units
	A, T :: f32(CROSSHAIR_ARM), f32(CROSSHAIR_THICKNESS)
	// Three rectangles, so the middle isn't inverted twice: the whole bar across, and the upright above and below it.
	rects := [3][4]f32{{-A, -T, A, T}, {-T, T, T, A}, {-T, -A, T, -T}}
	verts: [18][3]f32
	for rect, i in rects {
		x0, y0, x1, y1 := rect[0] * px.x, rect[1] * px.y, rect[2] * px.x, rect[3] * px.y
		quad := [6][3]f32{{x0, y0, 0}, {x1, y0, 0}, {x1, y1, 0}, {x0, y0, 0}, {x1, y1, 0}, {x0, y1, 0}}
		copy(verts[i * 6:], quad[:])
	}
	identity: matrix[4, 4]f32 = 1
	gl.Disable(gl.DEPTH_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR)
	gl.UseProgram(r.overlay_program)
	gl.UniformMatrix4fv(r.u_overlay_matrix, 1, false, &identity[0, 0])
	gl.Uniform4f(r.u_overlay_color, 1, 1, 1, 1)
	gl.BindVertexArray(r.overlay_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.overlay_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(verts) * size_of([3]f32), &verts[0])
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(verts)))
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
}
