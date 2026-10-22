package main

import gl "vendor:OpenGL"

// Enough for the worst case chunk (a 3D checkerboard) while indices still fit in u16.
MAX_QUADS_PER_CHUNK :: 16384

Chunk_Mesh :: struct {
	vao, vbo:    u32,
	index_count: i32,
}

Renderer :: struct {
	program:        u32,
	u_view_proj:    i32,
	u_chunk_origin: i32,
	texture:        u32,
	quad_ebo:       u32,
}

VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in float a_layer;
layout(location = 3) in float a_shade;

uniform mat4 u_view_proj;
uniform vec3 u_chunk_origin;

out vec2 v_uv;
flat out float v_layer;
out float v_shade;

void main() {
	gl_Position = u_view_proj * vec4(a_pos + u_chunk_origin, 1.0);
	v_uv = a_uv;
	v_layer = a_layer;
	v_shade = a_shade;
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

renderer_init :: proc(r: ^Renderer) -> bool {
	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		return false
	}
	r.program = program
	r.u_view_proj = gl.GetUniformLocation(program, "u_view_proj")
	r.u_chunk_origin = gl.GetUniformLocation(program, "u_chunk_origin")

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

	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)
	return true
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
		gl.VertexAttribPointer(1, 2, gl.FLOAT, false, stride, offset_of(Vertex, uv))
		gl.EnableVertexAttribArray(2)
		gl.VertexAttribPointer(2, 1, gl.FLOAT, false, stride, offset_of(Vertex, layer))
		gl.EnableVertexAttribArray(3)
		gl.VertexAttribPointer(3, 1, gl.FLOAT, false, stride, offset_of(Vertex, shade))
		gl.BindVertexArray(0)
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, mesh.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(vertices) * size_of(Vertex), raw_data(vertices), gl.STATIC_DRAW)
	mesh.index_count = i32(len(vertices) / 4 * 6)
}

// Builds and uploads every chunk; returns the number of faces drawn.
mesh_world :: proc(w: ^World, r: ^Renderer) -> int {
	vertices := make([dynamic]Vertex, 0, 4096)
	defer delete(vertices)
	faces := 0
	for _, chunk in w.chunks {
		build_chunk_mesh(w, chunk, &vertices)
		upload_chunk_mesh(r, &chunk.mesh, vertices[:])
		faces += len(vertices) / 4
	}
	return faces
}

renderer_draw_world :: proc(r: ^Renderer, w: ^World, view_proj: matrix[4, 4]f32) {
	view_proj := view_proj
	gl.UseProgram(r.program)
	gl.UniformMatrix4fv(r.u_view_proj, 1, false, &view_proj[0, 0])
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, r.texture)
	for _, chunk in w.chunks {
		if chunk.mesh.index_count == 0 {
			continue
		}
		origin := chunk.pos * CHUNK_SIZE
		gl.Uniform3f(r.u_chunk_origin, f32(origin.x), f32(origin.y), f32(origin.z))
		gl.BindVertexArray(chunk.mesh.vao)
		gl.DrawElements(gl.TRIANGLES, chunk.mesh.index_count, gl.UNSIGNED_SHORT, nil)
	}
}
