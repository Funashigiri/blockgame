package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

// --test plays the game by itself with simulated keys and checks that standing, jumping, walking and
// flying behave. Results go to test.txt (and the exit code), views from the walker's eyes to test_*.png.
TEST_FRAME :: 1.0 / 60

Test_Log :: struct {
	text:   strings.Builder,
	failed: int,
}

test_check :: proc(log: ^Test_Log, ok: bool, name, detail: string) {
	fmt.sbprintf(&log.text, "%s  %s: %s\n", "PASS" if ok else "FAIL", name, detail)
	if !ok {
		log.failed += 1
	}
}

test_step :: proc(w: ^World, p: ^Player, cam: ^Camera, input: Input) {
	player_update(w, p, cam.heading, input, TEST_FRAME)
	cam.pos = player_eye(p^)
	camera_align(cam)
}

test_hold :: proc(w: ^World, p: ^Player, cam: ^Camera, input: Input, seconds: f64) {
	for t := 0.0; t < seconds; t += TEST_FRAME {
		test_step(w, p, cam, input)
	}
}

// What the player would see, with crosshair and outline, saved as test_<n>.png.
test_screenshot :: proc(window: glfw.WindowHandle, r: ^Renderer, w: ^World, cam: Camera, n: int) {
	hit := raycast(w, cam.pos, look_direction(cam))
	target: Maybe(Block_Pos) = hit.block if hit.hit else nil
	if _, ok := draw_frame(window, r, w, cam, target, true); ok {
		save_screenshot(window, fmt.ctprintf("test_%d.png", n))
		glfw.SwapBuffers(window)
	}
}

feet_layer :: proc(p: Player) -> f64 {
	_, grid := world_to_face(p.pos)
	return grid.y
}

run_self_test :: proc(window: glfw.WindowHandle, r: ^Renderer, ui: ^UI, w: ^World) -> bool {
	log: Test_Log
	log.text = strings.builder_make()
	p := spawn_player()
	cam := spawn_camera()

	// Standing still: gravity settles the player exactly on top of the ground.
	MIDDLE :: FACE_BLOCKS / 2
	ground := f64(terrain_column(.PY, MIDDLE, MIDDLE).height + 1)
	test_hold(w, &p, &cam, {}, 1)
	test_check(&log, p.on_ground && abs(feet_layer(p) - ground) < 0.01, "stands on the ground",
		fmt.tprintf("feet at layer %.3f, top of ground %.0f", feet_layer(p), ground))

	// One jump from flat ground.
	start, peak := feet_layer(p), feet_layer(p)
	test_step(w, &p, &cam, {jump = true})
	for t := 0.0; t < 2; t += TEST_FRAME {
		test_step(w, &p, &cam, {})
		peak = max(peak, feet_layer(p))
	}
	test_check(&log, abs(peak - start - JUMP_HEIGHT) < 0.05 && p.on_ground, "jump",
		fmt.tprintf("rose %.3f blocks (want %.2f), landed %v", peak - start, JUMP_HEIGHT, p.on_ground))

	// Run around the planet: hop up single-block steps, turn aside when a cliff is in the way.
	// The player must never end up inside a block, and must cover a full lap's distance.
	travelled := 0.0
	faces: bit_set[Cube_Face]
	inside_frames, turns, shots := 0, 0, 0
	last := p.pos
	checkpoint, checkpoint_timer := p.pos, 0.0
	t := 0.0
	for ; t < 400 && travelled < 2 * math.PI; t += TEST_FRAME {
		input := Input{move = {0, 1}, sprint = true}
		up := linalg.normalize(p.pos)
		ground_speed := linalg.length(p.vel - up * linalg.dot(p.vel, up))
		if p.on_ground && t > 0.5 && ground_speed < SPRINT_SPEED / 2 {
			input.jump = true
		}
		test_step(w, &p, &cam, input)

		now := linalg.normalize(p.pos)
		travelled += math.atan2(linalg.length(linalg.cross(linalg.normalize(last), now)), linalg.dot(linalg.normalize(last), now))
		last = p.pos
		face, _ := world_to_face(p.pos)
		faces += {face}
		if player_inside_block(w, p) {
			inside_frames += 1
		}
		checkpoint_timer += TEST_FRAME
		if checkpoint_timer >= 1.5 {
			if linalg.length(p.pos - checkpoint) < 1 {
				camera_turn(&cam, 0.7)
				turns += 1
			}
			checkpoint, checkpoint_timer = p.pos, 0
		}
		if shots < 3 && t >= f64(20 + 60 * shots) {
			shots += 1
			test_screenshot(window, r, w, cam, shots)
		}
	}
	test_check(&log, travelled >= 2 * math.PI, "walk a lap",
		fmt.tprintf("covered %.0f%% of a lap in %.0f s, turned aside %d times", travelled / (2 * math.PI) * 100, t, turns))
	test_check(&log, inside_frames == 0, "never inside a block", fmt.tprintf("%d frames inside", inside_frames))
	test_check(&log, card(faces) >= 3, "crosses face edges", fmt.tprintf("walked on %d of 6 faces", card(faces)))

	// Flying: a double tap starts it, Space climbs, letting go hovers, Shift sinks, touching down ends it.
	test_hold(w, &p, &cam, {}, 1)
	start = feet_layer(p)
	test_step(w, &p, &cam, {toggle_fly = true})
	test_hold(w, &p, &cam, {jump = true}, 2)
	climbed := feet_layer(p) - start
	test_check(&log, p.flying && climbed > 18 && climbed < 23, "fly up",
		fmt.tprintf("climbed %.1f blocks in 2 s, flying %v", climbed, p.flying))
	test_hold(w, &p, &cam, {}, 0.5)
	hover_start := feet_layer(p)
	test_hold(w, &p, &cam, {}, 1)
	test_check(&log, p.flying && abs(feet_layer(p) - hover_start) < 0.01, "hover",
		fmt.tprintf("drifted %.3f blocks in 1 s", feet_layer(p) - hover_start))
	test_hold(w, &p, &cam, {descend = true}, 5)
	test_check(&log, !p.flying && p.on_ground, "landing ends flight",
		fmt.tprintf("flying %v, on ground %v", p.flying, p.on_ground))

	// Double tap timing, as read from the keyboard.
	keys := Key_State{last_jump_press = -1}
	taps := [?]struct {
		down: bool,
		at:   f64,
	}{{true, 1.0}, {false, 1.1}, {true, 1.2}, {false, 1.3}, {true, 1.4}, {false, 1.5}, {true, 2.0}, {false, 2.1}, {true, 2.6}}
	toggles: [dynamic]f64
	toggles.allocator = context.temp_allocator
	for tap in taps {
		if jump_double_tap(&keys, tap.down, tap.at) {
			append(&toggles, tap.at)
		}
	}
	test_check(&log, len(toggles) == 1 && toggles[0] == 1.2, "double tap",
		fmt.tprintf("switched at %v (want only at 1.2)", toggles[:]))

	// Building, back at the start: put a block on the ground a couple of steps ahead.
	p = spawn_player()
	cam = spawn_camera()
	test_hold(w, &p, &cam, {}, 1)
	slowest_edit := 0.0
	timed :: proc(slowest: ^f64, start: f64) {
		slowest^ = max(slowest^, glfw.GetTime() - start)
	}
	cam.pitch = -0.6
	hit := raycast(w, cam.pos, look_direction(cam))
	hotbar := new_hotbar()
	hotbar_pick(&hotbar, 4, 0) // planks
	start_time := glfw.GetTime()
	placed := hit.hit && place_selected(w, r, p, hit.before, hotbar)
	timed(&slowest_edit, start_time)
	there := world_get_block(w, hit.before.face, hit.before.x, hit.before.y, hit.before.z)
	test_check(&log, placed && there == .Planks, "place a block",
		fmt.tprintf("looking at %v, placed %v, block there now: %v", hit.block, placed, there))
	up := linalg.normalize(p.pos)
	own := block_at_world(p.pos + up * 0.5)
	test_check(&log, !try_place(w, r, p, own, .Stone), "can't place a block inside yourself", fmt.tprintf("cell %v", own))
	hotbar_pick(&hotbar, 5, 0) // the first empty slot
	hit = raycast(w, cam.pos, look_direction(cam))
	placed = place_selected(w, r, p, hit.before, hotbar)
	there = world_get_block(w, hit.before.face, hit.before.x, hit.before.y, hit.before.z)
	test_check(&log, hit.hit && !placed && there == .Air, "an empty slot places nothing",
		fmt.tprintf("placed %v, block there now: %v", placed, there))

	// A row of two-high pillars of every block in the hotbar, for a look at the textures.
	forward := linalg.normalize(([3]f64)(cam.heading))
	right := linalg.cross(forward, up)
	for block, i in HOTBAR {
		if block == .Air {
			continue
		}
		base := block_at_world(p.pos + forward * 4 + right * f64(i - 2) * 1.5 + up * 0.5)
		for level in i32(0) ..< 2 {
			start_time = glfw.GetTime()
			try_place(w, r, p, {base.face, base.x, base.y + level, base.z}, block)
			timed(&slowest_edit, start_time)
		}
	}
	cam.pitch = -0.25
	test_screenshot(window, r, w, cam, 4)

	// Digging straight down: every block under the feet breaks, until the core, which doesn't.
	cam.pitch = -PITCH_LIMIT
	dug := 0
	for _ in 0 ..< 200 {
		hit = raycast(w, cam.pos, look_direction(cam))
		if !hit.hit {
			break
		}
		start_time = glfw.GetTime()
		broke := try_break(w, r, hit.block)
		timed(&slowest_edit, start_time)
		if !broke {
			break
		}
		dug += 1
		test_hold(w, &p, &cam, {}, 0.6) // fall into the new hole and land
	}
	up = linalg.normalize(p.pos)
	below := block_at_world(p.pos - up * 0.5)
	standing_on := world_get_block(w, below.face, below.x, below.y, below.z)
	test_check(&log, abs(feet_layer(p) - CORE_TOP) < 0.01 && standing_on == .Core, "dig down to the core",
		fmt.tprintf("dug %d blocks, feet at layer %.2f (core starts below %d), standing on %v", dug, feet_layer(p), CORE_TOP, standing_on))
	hit = raycast(w, cam.pos, look_direction(cam))
	test_check(&log, hit.hit && !try_break(w, r, hit.block), "core can't be broken",
		fmt.tprintf("looking at %v", BLOCK_NAMES[world_get_block(w, hit.block.face, hit.block.x, hit.block.y, hit.block.z)]))
	cam.pitch = -0.9
	test_screenshot(window, r, w, cam, 5)
	cam.pitch = PITCH_LIMIT
	test_screenshot(window, r, w, cam, 6)
	test_check(&log, slowest_edit < 0.004, "edits are quick", fmt.tprintf("slowest break or place took %.2f ms", slowest_edit * 1000))

	test_interface(&log, window, r, ui, w)
	test_hud(&log, window, r, ui, w)

	fmt.sbprintf(&log.text, "\n%s\n", "ALL PASSED" if log.failed == 0 else fmt.tprintf("%d FAILED", log.failed))
	report := strings.to_string(log.text)
	if err := os.write_entire_file("test.txt", report); err != nil {
		fmt.eprintln("Could not write test.txt:", err)
	}
	fmt.print(report)
	return log.failed == 0
}

// Every letter the menus might ever need, and everything the pause menu actually says.
ALPHABETS :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя0123456789"

font_missing :: proc(f: ^Font, text: string) -> string {
	missing := strings.builder_make(context.temp_allocator)
	for r in text {
		if _, ok := font_glyph(f, r); !ok && r != ' ' {
			strings.write_rune(&missing, r)
		}
	}
	return strings.to_string(missing)
}

test_interface :: proc(log: ^Test_Log, window: glfw.WindowHandle, r: ^Renderer, ui: ^UI, w: ^World) {
	missing := font_missing(&ui.font, ALPHABETS)
	test_check(log, missing == "", "font has every letter", fmt.tprintf("%d glyphs, missing: \"%s\"", len(ui.font.glyphs), missing))

	// Render the pause menu once off-screen to collect its text, and check every character is drawable.
	width, height := glfw.GetFramebufferSize(window)
	menu_text := strings.builder_make(context.temp_allocator)
	for mode in Display_Mode {
		fmt.sbprintf(&menu_text, "Пауза Продолжить Экран: %s Выйти из игры Esc — вернуться в игру F11 — полный экран 60 FPS ", DISPLAY_MODE_NAMES[mode])
	}
	missing = font_missing(&ui.font, strings.to_string(menu_text))
	test_check(log, missing == "", "font covers the menu text", fmt.tprintf("missing: \"%s\"", missing))

	// The whole font on a dark background, for a look.
	cam := spawn_camera()
	draw_frame(window, r, w, cam)
	ui_begin(ui, width, height, {-1, -1}, false)
	ui_rect(ui, 0, 0, ui.size.x, ui.size.y, {20, 20, 30, 255})
	lines := [?]string {
		"ABCDEFGHIJKLMNOPQRSTUVWXYZ",
		"abcdefghijklmnopqrstuvwxyz",
		"АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ",
		"абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
		"0123456789 .,:;!?-—+=_()/%|'\"<>",
		"Съешь же ещё этих мягких французских булок, да выпей чаю.",
		"The quick brown fox jumps over the lazy dog.",
	}
	for line, i in lines {
		ui_text(ui, line, 8, 8 + f32(i) * 14, WHITE)
	}
	ui_end(ui)
	save_screenshot(window, "test_7.png")
	glfw.SwapBuffers(window)

	// Where the pause menu puts its buttons, in screen pixels (same layout as pause_menu).
	ui.scale = gui_scale(width, height)
	gui := [2]f32{f32(width), f32(height)} / ui.scale
	center := math.floor(gui.x / 2)
	first_button_y := math.floor(gui.y / 4) + 20
	button_center :: proc(center, first_y: f32, index: int, scale: f32) -> [2]f32 {
		return [2]f32{center, first_y + f32(index) * BUTTON_STEP + BUTTON_H / 2} * scale
	}

	// The pause menu over the world and the hotbar, with the mouse resting on the second button.
	draw_frame(window, r, w, cam)
	ui_begin(ui, width, height, button_center(center, first_button_y, 1, ui.scale), false)
	hud_hotbar(ui, new_hotbar(), 0)
	pause_menu(ui, .Windowed, 60)
	ui_end(ui)
	save_screenshot(window, "test_8.png")
	glfw.SwapBuffers(window)

	// Clicks land on the right buttons, and a click on empty space does nothing.
	clicks := [?]struct {
		mouse: [2]f32,
		want:  Menu_Action,
	} {
		{button_center(center, first_button_y, 0, ui.scale), .Resume},
		{button_center(center, first_button_y, 1, ui.scale), .Next_Display_Mode},
		{button_center(center, first_button_y, 2, ui.scale), .Quit},
		{{2, 2}, .None},
	}
	all_right := true
	got: [dynamic]Menu_Action
	got.allocator = context.temp_allocator
	for c in clicks {
		ui_begin(ui, width, height, c.mouse, true)
		action := pause_menu(ui, .Windowed, 60)
		append(&got, action)
		all_right &= action == c.want
	}
	clear(&ui.vertices)
	test_check(log, all_right, "menu buttons", fmt.tprintf("clicks gave %v", got[:]))

	// Each display mode: borderless and full screen cover the whole monitor, windowed comes back to its size.
	settings := DEFAULT_SETTINGS
	remember_window(window, &settings)
	window_size := settings.window_size
	video := glfw.GetVideoMode(glfw.GetPrimaryMonitor())
	settle :: proc() {
		for _ in 0 ..< 10 {
			glfw.WaitEventsTimeout(0.05)
		}
	}
	sizes: [Display_Mode][2]i32
	for mode in ([3]Display_Mode{.Borderless, .Fullscreen, .Windowed}) {
		apply_display_mode(window, &settings, mode)
		settle()
		fw, fh := glfw.GetFramebufferSize(window)
		sizes[mode] = {fw, fh}
	}
	screen := [2]i32{video.width, video.height}
	test_check(log, sizes[.Borderless] == screen && sizes[.Fullscreen] == screen && sizes[.Windowed] == window_size, "display modes",
		fmt.tprintf("borderless %v, full screen %v (screen %v), windowed %v (was %v)",
			sizes[.Borderless], sizes[.Fullscreen], screen, sizes[.Windowed], window_size))
	toggle_full_screen(window, &settings)
	settle()
	fw, fh := glfw.GetFramebufferSize(window)
	went_full := settings.display == .Fullscreen && [2]i32{fw, fh} == screen
	toggle_full_screen(window, &settings)
	settle()
	fw, fh = glfw.GetFramebufferSize(window)
	test_check(log, went_full && settings.display == .Windowed && [2]i32{fw, fh} == window_size, "F11",
		fmt.tprintf("full screen %v, back in a window %v", went_full, [2]i32{fw, fh}))

	// Settings survive a save and a load.
	saved := Settings{.Borderless, .Borderless, {12, 34}, {800, 600}}
	settings_save("test_settings.txt", saved)
	loaded := settings_load("test_settings.txt")
	_ = os.remove("test_settings.txt")
	test_check(log, loaded == saved, "settings are remembered", fmt.tprintf("saved %v, loaded %v", saved, loaded))
}

// The hotbar and the F3 screen: picking blocks with keys and the wheel, the name that fades,
// the compass, and that the font can write everything the F3 screen says.
test_hud :: proc(log: ^Test_Log, window: glfw.WindowHandle, r: ^Renderer, ui: ^UI, w: ^World) {
	// Wheel down steps right, wheel up steps left, round past either end; touchpad fractions add up.
	h := new_hotbar()
	moves := [?]f64{-1, 2, 1, 1, -1, -0.4, -0.4, -0.4}
	trail: [dynamic]int
	trail.allocator = context.temp_allocator
	for wheel, i in moves {
		hotbar_scroll(&h, wheel, f64(i))
		append(&trail, h.selected)
	}
	hotbar_pick(&h, 6, 10) // key 7
	append(&trail, h.selected)
	want := []int{3, 1, 0, 8, 0, 0, 0, 1, 6}
	same := len(trail) == len(want)
	for slot, i in trail {
		same &= i < len(want) && slot == want[i]
	}
	test_check(log, same, "hotbar wheel and keys", fmt.tprintf("slots %v (want %v)", trail[:], want))

	// The name of a picked block shows for a while, then fades; nothing shows at the start or for an empty slot.
	h = new_hotbar()
	at_start := hotbar_name_alpha(h, 0.5)
	hotbar_pick(&h, 3, 10) // sand
	shown := [3]f64{hotbar_name_alpha(h, 10.1), hotbar_name_alpha(h, 11.75), hotbar_name_alpha(h, 12.1)}
	hotbar_pick(&h, 7, 13)
	empty := hotbar_name_alpha(h, 13.1)
	test_check(log, at_start == 0 && shown == [3]f64{1, 0.5, 0} && empty == 0, "block name over the hotbar",
		fmt.tprintf("at start %.2f; after picking %.2f, %.2f, %.2f; empty slot %.2f", at_start, shown[0], shown[1], shown[2], empty))

	// The game starts next to 0°, 0° facing north; a right turn faces east; the +X face is at 90° east;
	// the north pole is the middle of the -Z face.
	cam := spawn_camera()
	latitude, longitude := latitude_longitude(cam.pos)
	bearing, _ := compass_bearing(cam.pos, cam.heading)
	turned := cam
	camera_turn(&turned, math.PI / 2)
	east, _ := compass_bearing(turned.pos, turned.heading)
	_, east_longitude := latitude_longitude({PLANET_RADIUS, 0, 0})
	pole_latitude, _ := latitude_longitude(NORTH_POLE * PLANET_RADIUS)
	_, at_pole := compass_bearing(NORTH_POLE * PLANET_RADIUS, {1, 0, 0})
	test_check(log,
		abs(latitude) < 0.5 && abs(longitude) < 0.5 && compass_point(bearing) == "север" && compass_point(east) == "восток" &&
		abs(east_longitude - 90) < 0.01 && abs(pole_latitude - 90) < 0.01 && at_pole, "compass",
		fmt.tprintf("start at %.2f, %.2f facing %.0f° (%s); turned right %.0f° (%s); +X face at %.1f° east; pole at %.1f°, at pole %v",
			latitude, longitude, bearing, compass_point(bearing), east, compass_point(east), east_longitude, pole_latitude, at_pole))

	// Every line the F3 screen can show: both hemispheres, both poles, every compass point, every block.
	gpu := string(gl.GetString(gl.RENDERER))
	text := strings.builder_make(context.temp_allocator)
	places := [?][3]f64{{0, 1, 0}, {-1, -1, 1}, NORTH_POLE, -NORTH_POLE}
	for place, i in places {
		info := Debug_Info{fps = 60, feet = place * PLANET_RADIUS, heading = {1, 0, 0}, flying = i % 2 == 0, gpu = gpu}
		info.looking_at = .Stone if i % 2 == 0 else .Air
		left, right := debug_lines(info)
		for line in left {
			fmt.sbprintf(&text, "%s ", line)
		}
		for line in right {
			fmt.sbprintf(&text, "%s ", line)
		}
	}
	for point in COMPASS_POINTS {
		fmt.sbprintf(&text, "%s ", point)
	}
	for name in BLOCK_NAMES {
		fmt.sbprintf(&text, "%s ", name)
	}
	missing := font_missing(&ui.font, strings.to_string(text))
	test_check(log, missing == "", "font covers the hotbar and F3 text", fmt.tprintf("missing: \"%s\"", missing))

	// The view on starting, with a block just picked and the F3 screen on.
	width, height := glfw.GetFramebufferSize(window)
	hit := raycast(w, cam.pos, look_direction(cam))
	target: Maybe(Block_Pos) = hit.block if hit.hit else nil
	drawn, _ := draw_frame(window, r, w, cam, target, true)
	h = new_hotbar()
	hotbar_pick(&h, 4, 0) // planks, picked just now
	looking: Block = .Air
	if hit.hit {
		looking = world_get_block(w, hit.block.face, hit.block.x, hit.block.y, hit.block.z)
	}
	start_time := glfw.GetTime()
	ui_begin(ui, width, height, {-1, -1}, false)
	hud_hotbar(ui, h, 0.1)
	debug_screen(ui, Debug_Info {
		fps = 60,
		worst_frame = TEST_FRAME,
		feet = spawn_player().pos,
		heading = cam.heading,
		looking_at = looking,
		chunks_drawn = drawn,
		chunks_with_blocks = count_chunks_with_blocks(w),
		screen = {width, height},
		refresh_rate = int(glfw.GetVideoMode(glfw.GetPrimaryMonitor()).refresh_rate),
		gpu = gpu,
	})
	build_seconds := glfw.GetTime() - start_time
	quads := len(ui.vertices) / 6
	ui_end(ui)
	save_screenshot(window, "test_9.png")
	glfw.SwapBuffers(window)
	test_check(log, build_seconds < 0.001, "hotbar and F3 are quick",
		fmt.tprintf("%d pieces, laid out in %.3f ms (F3 included)", quads, build_seconds * 1000))
}
