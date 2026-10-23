package main

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"

// Menus are laid out in "GUI pixels" and blown up by a whole number, like Minecraft,
// so the pixel font and the buttons always stay crisp.
UI_Vertex :: struct {
	pos:   [2]f32, // screen pixels, from the top-left corner
	uv:    [2]f32,
	color: [4]u8,
	layer: f32, // block texture layer for block pictures, FONT_LAYER for text and plain rectangles
}

FONT_LAYER :: -1

Color :: [4]u8

WHITE       :: Color{255, 255, 255, 255}
HOVER_TEXT  :: Color{255, 255, 160, 255}
HINT_TEXT   :: Color{200, 200, 200, 255}
BUTTON_W    :: 200
BUTTON_H    :: 20
BUTTON_STEP :: 24 // from the top of one button to the top of the next

UI_VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
layout(location = 3) in float a_layer;
uniform vec2 u_screen;
out vec2 v_uv;
out vec4 v_color;
flat out float v_layer;
void main() {
	vec2 ndc = a_pos / u_screen * 2.0 - 1.0;
	gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
	v_uv = a_uv;
	v_color = a_color;
	v_layer = a_layer;
}
`

// Text and rectangles take their shape from the font texture; block pictures use the world's block textures,
// so the whole interface is still one draw.
UI_FRAGMENT_SHADER :: `#version 330 core
in vec2 v_uv;
in vec4 v_color;
flat in float v_layer;
uniform sampler2D u_font;
uniform sampler2DArray u_blocks;
out vec4 frag_color;
void main() {
	if (v_layer < 0.0) {
		frag_color = vec4(v_color.rgb, v_color.a * texture(u_font, v_uv).r);
	} else {
		frag_color = vec4(texture(u_blocks, vec3(v_uv, v_layer)).rgb * v_color.rgb, v_color.a);
	}
}
`

UI :: struct {
	program, texture, vao, vbo: u32,
	blocks_texture:             u32, // the renderer's block texture array
	u_screen:                   i32,
	vertices:                   [dynamic]UI_Vertex,
	font:                       Font,
	scale:                      f32,    // screen pixels per GUI pixel
	screen:                     [2]f32, // screen size in screen pixels
	size:                       [2]f32, // screen size in GUI pixels
	mouse:                      [2]f32, // in GUI pixels
	clicked:                    bool,   // the left button went down this frame
}

ui_init :: proc(ui: ^UI, blocks_texture: u32) -> bool {
	program, ok := gl.load_shaders_source(UI_VERTEX_SHADER, UI_FRAGMENT_SHADER)
	if !ok {
		return false
	}
	ui.program = program
	ui.u_screen = gl.GetUniformLocation(program, "u_screen")
	ui.blocks_texture = blocks_texture
	gl.UseProgram(program)
	gl.Uniform1i(gl.GetUniformLocation(program, "u_font"), 0)
	gl.Uniform1i(gl.GetUniformLocation(program, "u_blocks"), 1)

	font_build(&ui.font)
	gl.GenTextures(1, &ui.texture)
	gl.BindTexture(gl.TEXTURE_2D, ui.texture)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, FONT_ATLAS_W, FONT_ATLAS_H, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(ui.font.pixels))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenVertexArrays(1, &ui.vao)
	gl.GenBuffers(1, &ui.vbo)
	gl.BindVertexArray(ui.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ui.vbo)
	stride := i32(size_of(UI_Vertex))
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, stride, offset_of(UI_Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, stride, offset_of(UI_Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, stride, offset_of(UI_Vertex, color))
	gl.EnableVertexAttribArray(3)
	gl.VertexAttribPointer(3, 1, gl.FLOAT, false, stride, offset_of(UI_Vertex, layer))
	gl.BindVertexArray(0)
	return true
}

// Minecraft's rule: the biggest whole scale that still leaves at least 320 x 240 GUI pixels.
gui_scale :: proc(width, height: i32) -> f32 {
	return f32(max(1, min(width / 320, height / 240)))
}

// mouse is in screen pixels.
ui_begin :: proc(ui: ^UI, width, height: i32, mouse: [2]f32, clicked: bool) {
	ui.scale = gui_scale(width, height)
	ui.screen = {f32(width), f32(height)}
	ui.size = ui.screen / ui.scale
	ui.mouse = mouse / ui.scale
	ui.clicked = clicked
	clear(&ui.vertices)
}

ui_quad :: proc(ui: ^UI, x, y, w, h: f32, uv0, uv1: [2]f32, color: Color) {
	s := ui.scale
	x0, y0, x1, y1 := x * s, y * s, (x + w) * s, (y + h) * s
	append(&ui.vertices,
		UI_Vertex{{x0, y0}, {uv0.x, uv0.y}, color, FONT_LAYER}, UI_Vertex{{x1, y0}, {uv1.x, uv0.y}, color, FONT_LAYER},
		UI_Vertex{{x1, y1}, {uv1.x, uv1.y}, color, FONT_LAYER}, UI_Vertex{{x0, y0}, {uv0.x, uv0.y}, color, FONT_LAYER},
		UI_Vertex{{x1, y1}, {uv1.x, uv1.y}, color, FONT_LAYER}, UI_Vertex{{x0, y1}, {uv0.x, uv1.y}, color, FONT_LAYER})
}

// A plain rectangle: samples the solid cell of the font texture.
ui_rect :: proc(ui: ^UI, x, y, w, h: f32, color: Color) {
	solid := [2]f32{f32(FONT_CELL_W / 2) / FONT_ATLAS_W, f32(FONT_CELL_H / 2) / FONT_ATLAS_H}
	ui_quad(ui, x, y, w, h, solid, solid, color)
}

// A hollow rectangle: lines `thickness` pixels wide just inside x, y, w, h.
ui_frame :: proc(ui: ^UI, x, y, w, h, thickness: f32, color: Color) {
	t := thickness
	ui_rect(ui, x, y, w, t, color)
	ui_rect(ui, x, y + h - t, w, t, color)
	ui_rect(ui, x, y + t, t, h - 2 * t, color)
	ui_rect(ui, x + w - t, y + t, t, h - 2 * t, color)
}

// One side of a block picture: a block texture stretched over any four corners, given clockwise
// from the texture's top-left. color darkens it, for sides in shade.
ui_block_side :: proc(ui: ^UI, corners: [4][2]f32, tex: Tex, color: Color) {
	uvs := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	v: [4]UI_Vertex
	for corner, i in corners {
		v[i] = {corner * ui.scale, uvs[i], color, f32(tex)}
	}
	append(&ui.vertices, v[0], v[1], v[2], v[0], v[2], v[3])
}

// A block as Minecraft pictures it in the hotbar: a 10-pixel cube turned 45° and tipped 30° towards
// the viewer, lit from above, its two visible sides in shade. Fits a 16 x 16 square around center.
ui_block_icon :: proc(ui: ^UI, block: Block, center: [2]f32) {
	HALF_WIDTH :: 7.07       // 10 * sqrt(2) / 2
	TOP_HALF_HEIGHT :: 3.54  // HALF_WIDTH * sin 30°
	EDGE :: 8.66             // 10 * cos 30°, the upright edges
	top := center - {0, TOP_HALF_HEIGHT + EDGE / 2}
	left, right := top + {-HALF_WIDTH, TOP_HALF_HEIGHT}, top + {HALF_WIDTH, TOP_HALF_HEIGHT}
	front := top + {0, 2 * TOP_HALF_HEIGHT}
	down := [2]f32{0, EDGE}
	ui_block_side(ui, {top, right, front, left}, block_texture(block, .Up), WHITE)
	ui_block_side(ui, {left, front, front + down, left + down}, block_texture(block, .South), {204, 204, 204, 255})
	ui_block_side(ui, {front, right, right + down, front + down}, block_texture(block, .East), {153, 153, 153, 255})
}

// x, y is the top-left corner of the capitals. A dark copy one pixel down-right gives the Minecraft shadow.
ui_text :: proc(ui: ^UI, text: string, x, y: f32, color: Color, shadow := true) {
	if shadow {
		ui_text_raw(ui, text, x + 1, y + 1, {color.r / 4, color.g / 4, color.b / 4, color.a})
	}
	ui_text_raw(ui, text, x, y, color)
}

ui_text_raw :: proc(ui: ^UI, text: string, x, y: f32, color: Color) {
	pen := x
	for r in text {
		if r == ' ' {
			pen += FONT_SPACE_WIDTH + 1
			continue
		}
		g, _ := font_glyph(&ui.font, r)
		cell_x, cell_y := f32(g.cell % FONT_COLUMNS * FONT_CELL_W), f32(g.cell / FONT_COLUMNS * FONT_CELL_H)
		uv0 := [2]f32{cell_x / FONT_ATLAS_W, cell_y / FONT_ATLAS_H}
		uv1 := [2]f32{(cell_x + FONT_CELL_W) / FONT_ATLAS_W, (cell_y + FONT_CELL_H) / FONT_ATLAS_H}
		ui_quad(ui, pen, y, FONT_CELL_W, FONT_CELL_H, uv0, uv1, color)
		pen += f32(g.width + 1)
	}
}

ui_text_centered :: proc(ui: ^UI, text: string, center_x, y: f32, color: Color) {
	ui_text(ui, text, math.floor(center_x - f32(font_text_width(&ui.font, text)) / 2), y, color)
}

// A Minecraft-style button: grey face with a light top edge and a dark bottom edge, bluish under the mouse.
ui_button :: proc(ui: ^UI, label: string, x, y, w, h: f32) -> (clicked: bool) {
	hover := ui.mouse.x >= x && ui.mouse.x < x + w && ui.mouse.y >= y && ui.mouse.y < y + h
	face := Color{125, 130, 180, 255} if hover else Color{110, 110, 110, 255}
	ui_rect(ui, x, y, w, h, {0, 0, 0, 255})
	ui_rect(ui, x + 1, y + 1, w - 2, h - 2, face)
	ui_rect(ui, x + 1, y + 1, w - 2, 1, {face.r + 40, face.g + 40, face.b + 40, 255})
	ui_rect(ui, x + 1, y + h - 2, w - 2, 1, {face.r / 2, face.g / 2, face.b / 2, 255})
	ui_text_centered(ui, label, x + w / 2, y + math.floor((h - FONT_CAP_HEIGHT) / 2), HOVER_TEXT if hover else WHITE)
	return hover && ui.clicked
}

// Draws everything queued since ui_begin on top of the frame.
ui_end :: proc(ui: ^UI) {
	if len(ui.vertices) == 0 {
		return
	}
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.UseProgram(ui.program)
	gl.Uniform2f(ui.u_screen, ui.screen.x, ui.screen.y)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D_ARRAY, ui.blocks_texture)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, ui.texture)
	gl.BindVertexArray(ui.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ui.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(ui.vertices) * size_of(UI_Vertex), raw_data(ui.vertices), gl.STREAM_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(ui.vertices)))
	gl.Disable(gl.BLEND)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}

Menu_Action :: enum {
	None,
	Resume,
	Next_Display_Mode,
	Quit,
}

// The Esc menu: the world stays visible, dimmed, behind it. The FPS corner is left out when the F3 screen
// already shows it.
pause_menu :: proc(ui: ^UI, display: Display_Mode, fps: int, show_fps := true) -> (action: Menu_Action) {
	ui_rect(ui, 0, 0, ui.size.x, ui.size.y, {0, 0, 0, 140})
	center := math.floor(ui.size.x / 2)
	y := math.floor(ui.size.y / 4)
	ui_text_centered(ui, "Пауза", center, y, WHITE)
	x := center - BUTTON_W / 2
	y += 20
	if ui_button(ui, "Продолжить", x, y, BUTTON_W, BUTTON_H) {
		action = .Resume
	}
	y += BUTTON_STEP
	if ui_button(ui, fmt.tprintf("Экран: %s", DISPLAY_MODE_NAMES[display]), x, y, BUTTON_W, BUTTON_H) {
		action = .Next_Display_Mode
	}
	y += BUTTON_STEP
	if ui_button(ui, "Выйти из игры", x, y, BUTTON_W, BUTTON_H) {
		action = .Quit
	}
	// Under the buttons, clear of the hotbar at the bottom of the screen.
	ui_text_centered(ui, "Esc — вернуться в игру     F11 — полный экран", center, y + BUTTON_H + 16, HINT_TEXT)
	if show_fps {
		ui_text(ui, fmt.tprintf("%d FPS", fps), 4, 4, WHITE)
	}
	return
}
