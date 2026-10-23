package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

// The game's screens: the main menu it opens on, play, the Esc menu, and the settings.
Screen :: enum {
	Main_Menu,
	Playing,
	Paused,
	Options,
}

Menu_Action :: enum {
	None,
	Play,
	Pause,
	Resume,
	Options,
	Main_Menu,
	Quit,
	Toggle_Vsync,
	Next_Display_Mode,
	Done, // leave the settings
}

SPLASH_TEXT :: Color{255, 255, 85, 255}

TITLE_SIZE         :: 4     // the game's name on the main menu: each font pixel this many GUI pixels across
TITLE_TURN_SECONDS :: 240.0 // the planet behind the main menu turns once in this long
TITLE_HEIGHT       :: 320.0 // how far above the ground the main menu's camera floats
TITLE_PITCH        :: -1.35 // looking down at the planet, but a little above its middle, so the name sits in space

// The planet turning slowly behind the main menu, seen from space with its +Y pole at the top.
title_camera :: proc(t: f64) -> Camera {
	angle := t / TITLE_TURN_SECONDS * 2 * math.PI
	up := linalg.normalize([3]f64{math.cos(angle), 0.35, math.sin(angle)})
	pole := [3]f64{0, 1, 0}
	cam := Camera {
		pos     = up * (PLANET_RADIUS + TITLE_HEIGHT),
		heading = ([3]f32)(linalg.normalize(pole - up * linalg.dot(pole, up))),
		pitch   = TITLE_PITCH,
	}
	return cam
}

// The screen the game opens on, over the turning planet.
main_menu :: proc(ui: ^UI) -> (action: Menu_Action) {
	center := math.floor(ui.size.x / 2)
	y := math.floor(ui.size.y / 5)
	ui_text_centered(ui, GAME_NAME, center, y, WHITE, size = TITLE_SIZE)
	ui_text_centered(ui, "Целая планета из блоков", center, y + FONT_CAP_HEIGHT * TITLE_SIZE + 8, SPLASH_TEXT)
	x := center - BUTTON_W / 2
	y = math.floor(ui.size.y / 2) - 6
	if ui_button(ui, "Играть", x, y, BUTTON_W, BUTTON_H) {
		action = .Play
	}
	y += BUTTON_STEP
	if ui_button(ui, "Настройки", x, y, BUTTON_W, BUTTON_H) {
		action = .Options
	}
	y += BUTTON_STEP
	if ui_button(ui, "Выйти из игры", x, y, BUTTON_W, BUTTON_H) {
		action = .Quit
	}
	bottom := math.floor(ui.size.y) - 10
	ui_text(ui, fmt.tprintf("%s %s", GAME_NAME, VERSION), 2, bottom, WHITE)
	license := "Свободная игра, GPL-3.0"
	ui_text(ui, license, math.floor(ui.size.x) - 2 - f32(font_text_width(&ui.font, license)), bottom, WHITE)
	return
}

// The Esc menu: the world stays visible, dimmed, behind it. The FPS corner is left out when the F3 screen
// already shows it.
pause_menu :: proc(ui: ^UI, fps: int, show_fps := true) -> (action: Menu_Action) {
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
	if ui_button(ui, "Настройки", x, y, BUTTON_W, BUTTON_H) {
		action = .Options
	}
	y += BUTTON_STEP
	if ui_button(ui, "В главное меню", x, y, BUTTON_W, BUTTON_H) {
		action = .Main_Menu
	}
	// Under the buttons, clear of the hotbar at the bottom of the screen.
	ui_text_centered(ui, "Esc — вернуться в игру     F11 — полный экран", center, y + BUTTON_H + 16, HINT_TEXT)
	if show_fps {
		ui_text(ui, fmt.tprintf("%d FPS", fps), 4, 4, WHITE)
	}
	return
}

Option :: enum {
	Sensitivity,
	Fov,
	Vsync,
	Render_Distance,
	Display,
}

// Shown under the settings for the one under the mouse.
@(rodata)
OPTION_HINTS := [Option]string {
	.Sensitivity     = "Как быстро взгляд следует за мышью",
	.Fov             = "Шире — больше видно по краям",
	.Vsync           = "Вкл — плавно, без разрывов; выкл — FPS без предела",
	.Render_Distance = "Как далеко видно; меньше — быстрее",
	.Display         = "Окно, окно без рамки или полный экран",
}

// The settings, from the main menu or the Esc menu. Sliders change s straight away, so the world behind
// shows the new field of view and render distance while the slider moves.
options_menu :: proc(ui: ^UI, s: ^Settings) -> (action: Menu_Action) {
	ui_rect(ui, 0, 0, ui.size.x, ui.size.y, {0, 0, 0, 140})
	center := math.floor(ui.size.x / 2)
	x := center - BUTTON_W / 2
	y := math.floor(ui.size.y / 6)
	ui_text_centered(ui, "Настройки", center, y, WHITE)
	y += 20
	hint := ""
	for option in Option {
		if ui_hovered(ui, x, y, BUTTON_W, BUTTON_H) && ui.dragging == 0 || ui.dragging == int(option) + 1 {
			hint = OPTION_HINTS[option]
		}
		// Slider ids are the option's number plus one, as 0 means no slider.
		id := int(option) + 1
		switch option {
		case .Sensitivity:
			ui_slider(ui, id, fmt.tprintf("Чувствительность мыши: %d%%", s.sensitivity), &s.sensitivity, SENSITIVITY_RANGE, x, y, BUTTON_W, BUTTON_H)
		case .Fov:
			ui_slider(ui, id, fmt.tprintf("Поле зрения: %d°", s.fov), &s.fov, FOV_RANGE, x, y, BUTTON_W, BUTTON_H)
		case .Vsync:
			if ui_button(ui, fmt.tprintf("Синхронизация: %s", "вкл" if s.vsync else "выкл"), x, y, BUTTON_W, BUTTON_H) {
				action = .Toggle_Vsync
			}
		case .Render_Distance:
			n := s.render_distance
			label := fmt.tprintf("Дальность прорисовки: %d %s", n, plural(n, "чанк", "чанка", "чанков"))
			ui_slider(ui, id, label, &s.render_distance, RENDER_DISTANCE_RANGE, x, y, BUTTON_W, BUTTON_H)
		case .Display:
			if ui_button(ui, fmt.tprintf("Экран: %s", DISPLAY_MODE_NAMES[s.display]), x, y, BUTTON_W, BUTTON_H) {
				action = .Next_Display_Mode
			}
		}
		y += BUTTON_STEP
	}
	y += 8
	if ui_button(ui, "Готово", x, y, BUTTON_W, BUTTON_H) {
		action = .Done
	}
	ui_text_centered(ui, hint, center, y + BUTTON_H + 12, HINT_TEXT)
	return
}

// The Russian word for a count: 1 чанк, 2 чанка, 5 чанков, 21 чанк, 12 чанков.
plural :: proc(n: int, one, few, many: string) -> string {
	n10, n100 := n % 10, n % 100
	switch {
	case n10 == 1 && n100 != 11:
		return one
	case n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14):
		return few
	}
	return many
}
