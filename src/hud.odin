package main

import "core:fmt"
import "core:math"

// What stays on screen while playing: the hotbar at the bottom, and the F3 screen when it is on.

HOTBAR_SLOTS :: 9

// What the hotbar holds, slot by slot; Air is an empty slot.
@(rodata)
HOTBAR := [HOTBAR_SLOTS]Block{.Grass, .Dirt, .Stone, .Sand, .Planks, .Air, .Air, .Air, .Air}

// In GUI pixels, as in Minecraft.
HOTBAR_W  :: 182
HOTBAR_H  :: 22
SLOT_STEP :: 20

NAME_SECONDS      :: 2.0 // a block's name stays over the hotbar this long after it is picked
NAME_FADE_SECONDS :: 0.5 // fading out over the last part of that

Hotbar :: struct {
	selected:  int,
	picked_at: f64, // when the selection last changed
	wheel:     f64, // wheel movement not yet added up to a whole slot
}

// Starts on stone, with no name showing.
new_hotbar :: proc() -> Hotbar {
	return {selected = 2, picked_at = -NAME_SECONDS}
}

hotbar_pick :: proc(h: ^Hotbar, slot: int, now: f64) {
	if slot != h.selected {
		h.selected = slot
		h.picked_at = now
	}
}

// Wheel up moves one slot left, wheel down one slot right, and past the end round to the other side,
// as in Minecraft. A touchpad sends small fractions of a step; they add up.
hotbar_scroll :: proc(h: ^Hotbar, wheel, now: f64) {
	h.wheel += wheel
	steps := int(h.wheel)
	h.wheel -= f64(steps)
	if steps != 0 {
		hotbar_pick(h, (h.selected - steps) %% HOTBAR_SLOTS, now)
	}
}

hotbar_block :: proc(h: Hotbar) -> Block {
	return HOTBAR[h.selected]
}

// How visible the picked block's name is, from 1 down to 0: fully for a while, then fading away.
hotbar_name_alpha :: proc(h: Hotbar, now: f64) -> f64 {
	if hotbar_block(h) == .Air {
		return 0
	}
	return clamp((NAME_SECONDS - (now - h.picked_at)) / NAME_FADE_SECONDS, 0, 1)
}

// Places the block in the selected slot; an empty slot places nothing.
place_selected :: proc(w: ^World, r: ^Renderer, p: Player, pos: Block_Pos, h: Hotbar) -> bool {
	block := hotbar_block(h)
	return block != .Air && try_place(w, r, p, pos, block)
}

// Top-left corner of the hotbar, which sits in the middle at the bottom of the screen.
hotbar_origin :: proc(ui: ^UI) -> [2]f32 {
	return {math.floor(ui.size.x / 2) - HOTBAR_W / 2, math.floor(ui.size.y) - HOTBAR_H}
}

hud_hotbar :: proc(ui: ^UI, h: Hotbar, now: f64) {
	o := hotbar_origin(ui)
	ui_rect(ui, o.x, o.y, HOTBAR_W, HOTBAR_H, {0, 0, 0, 120})
	ui_frame(ui, o.x, o.y, HOTBAR_W, HOTBAR_H, 1, {0, 0, 0, 200})
	for slot in 0 ..< HOTBAR_SLOTS {
		ui_frame(ui, o.x + 1 + f32(slot) * SLOT_STEP, o.y + 1, SLOT_STEP, SLOT_STEP, 1, {140, 140, 140, 200})
	}
	// The picked slot gets a thick light frame that sticks out past the bar.
	picked := o.x - 1 + f32(h.selected) * SLOT_STEP
	ui_frame(ui, picked, o.y - 1, 24, 24, 1, {0, 0, 0, 255})
	ui_frame(ui, picked + 1, o.y, 22, 22, 2, {235, 235, 235, 255})
	for block, slot in HOTBAR {
		if block != .Air {
			ui_block_icon(ui, block, {o.x + 11 + f32(slot) * SLOT_STEP, o.y + 11})
		}
	}
	if alpha := hotbar_name_alpha(h, now); alpha > 0 {
		ui_text_centered(ui, BLOCK_NAMES[hotbar_block(h)], o.x + HOTBAR_W / 2, o.y - 14, {255, 255, 255, u8(alpha * 255)})
	}
}

// What the F3 screen shows.
Debug_Info :: struct {
	fps:                int,
	worst_frame:        f64, // seconds: the slowest frame of the last second
	feet:               [3]f64,
	heading:            [3]f32,
	looking_at:         Block, // Air when no block is within reach
	flying:             bool,
	chunks_drawn:       int,
	chunks_with_blocks: int,
	screen:             [2]i32,
	refresh_rate:       int,
	gpu:                string,
}

DEBUG_TEXT :: Color{224, 224, 224, 255}
DEBUG_BACK :: Color{80, 80, 80, 144}

@(rodata)
COMPASS_POINTS := [8]string{"север", "северо-восток", "восток", "юго-восток", "юг", "юго-запад", "запад", "северо-запад"}

compass_point :: proc(degrees: f64) -> string {
	return COMPASS_POINTS[int(math.floor(degrees / 45 + 0.5)) % 8]
}

// "12.34° с.ш." and the like; a value that rounds to zero counts as the plus side.
degrees_with_side :: proc(value: f64, plus, minus: string) -> string {
	return fmt.tprintf("%.2f° %s", abs(value), plus if value > -0.005 else minus)
}

// The F3 screen's lines: about the player on the left, about the computer on the right.
debug_lines :: proc(info: Debug_Info) -> (left, right: [dynamic]string) {
	left = make([dynamic]string, context.temp_allocator)
	right = make([dynamic]string, context.temp_allocator)
	latitude, longitude := latitude_longitude(info.feet)
	_, grid := world_to_face(info.feet)
	facing: string
	if bearing, at_pole := compass_bearing(info.feet, info.heading); at_pole {
		facing = "Ты на полюсе: все стороны — юг" if latitude > 0 else "Ты на полюсе: все стороны — север"
	} else {
		facing = fmt.tprintf("Смотришь на %s (%d°)", compass_point(bearing), int(math.round(bearing)) %% 360)
	}
	append(&left,
		fmt.tprintf("%s %s", GAME_NAME, VERSION),
		fmt.tprintf("%d FPS, самый долгий кадр %.1f мс", info.fps, info.worst_frame * 1000),
		fmt.tprintf("Широта %s, долгота %s", degrees_with_side(latitude, "с.ш.", "ю.ш."), degrees_with_side(longitude, "в.д.", "з.д.")),
		fmt.tprintf("Высота %.1f м", grid.y),
		facing,
		fmt.tprintf("Под прицелом: %s", BLOCK_NAMES[info.looking_at] if info.looking_at != .Air else "ничего"),
		fmt.tprintf("Режим: %s", "полёт" if info.flying else "ходьба"),
	)
	append(&right,
		fmt.tprintf("Видеокарта: %s", info.gpu),
		fmt.tprintf("Чанков на экране: %d из %d", info.chunks_drawn, info.chunks_with_blocks),
		fmt.tprintf("Экран %d x %d, %d Гц", info.screen.x, info.screen.y, info.refresh_rate),
	)
	return
}

// Plain lines over see-through grey, like Minecraft's F3 screen.
debug_screen :: proc(ui: ^UI, info: Debug_Info) {
	left, right := debug_lines(info)
	for line, i in left {
		debug_line(ui, line, 2, 2 + f32(i) * FONT_LINE_HEIGHT)
	}
	for line, i in right {
		debug_line(ui, line, math.floor(ui.size.x) - 2 - f32(font_text_width(&ui.font, line)), 2 + f32(i) * FONT_LINE_HEIGHT)
	}
}

debug_line :: proc(ui: ^UI, text: string, x, y: f32) {
	ui_rect(ui, x - 1, y - 1, f32(font_text_width(&ui.font, text)) + 2, FONT_LINE_HEIGHT, DEBUG_BACK)
	ui_text(ui, text, x, y, DEBUG_TEXT, shadow = false)
}

// Chunks that have any block side to draw.
count_chunks_with_blocks :: proc(w: ^World) -> (count: int) {
	for _, chunk in w.chunks {
		if chunk.mesh.index_count > 0 {
			count += 1
		}
	}
	return
}
