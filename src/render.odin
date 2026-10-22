package main

import "core:math"
import gl "vendor:OpenGL"

// Enough for the worst case chunk (a 3D checkerboard) while indices still fit in u16.
MAX_QUADS_PER_CHUNK :: 16384

STAR_COUNT :: 4000

Chunk_Mesh :: struct {
	vao, vbo:    u32,
	index_count: i32,
}

Renderer :: struct {
	program:         u32,
	u_view_proj:     i32,
	u_chunk_offset:  i32,
	texture:         u32,
	quad_ebo:        u32,
	star_program:    u32,
	u_star_view_proj: i32,
	star_vao:        u32,
}

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

// Builds and uploads every chunk; returns the number of block sides drawn.
mesh_world :: proc(w: ^World, r: ^Renderer) -> int {
	vertices := make([dynamic]Vertex, 0, 4096)
	defer delete(vertices)
	sides := 0
	for _, chunk in w.chunks {
		build_chunk_mesh(w, chunk, &vertices)
		upload_chunk_mesh(r, &chunk.mesh, vertices[:])
		sides += len(vertices) / 4
	}
	return sides
}

// view_proj must be rotation-only: every chunk is placed relative to the camera, so numbers stay small
// and precise however far from the planet centre the camera is.
renderer_draw :: proc(r: ^Renderer, w: ^World, view_proj: matrix[4, 4]f32, camera_pos: [3]f64) {
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
	for _, chunk in w.chunks {
		if chunk.mesh.index_count == 0 {
			continue
		}
		offset := ([3]f32)(chunk.anchor - camera_pos)
		gl.Uniform3f(r.u_chunk_offset, offset.x, offset.y, offset.z)
		gl.BindVertexArray(chunk.mesh.vao)
		gl.DrawElements(gl.TRIANGLES, chunk.mesh.index_count, gl.UNSIGNED_SHORT, nil)
	}
}
