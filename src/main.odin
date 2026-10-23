package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"
import stbi "vendor:stb/image"

GAME_NAME :: "blockgame"
VERSION   :: "0.0.7"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

SPACE_COLOR :: [3]f32{0.01, 0.01, 0.025}

// Start standing in the middle of the top face, looking out a little below the horizon.
SPAWN_PITCH :: -0.1

FOV_DEGREES        :: 70.0
NEAR_PLANE         :: 0.05
FAR_PLANE          :: 2000.0
FLY_SPEED          :: 11.0 // blocks per second
SPRINT_MULTIPLIER  :: 2.5  // Ctrl while flying
MOUSE_SENSITIVITY  :: 0.0022 // radians per pixel
DOUBLE_TAP_SECONDS :: 0.3  // two jump presses this close together switch flying on or off

Key_State :: struct {
	jump_was_down:   bool,
	last_jump_press: f64,
}

// Mouse wheel movement since it was last read; GLFW reports it through a callback.
wheel_moved: f64

wheel_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	wheel_moved += y
}

// --bench flies a fixed circle around the planet and writes bench.txt.
// Without a frame cap it shows the headroom; --bench-vsync runs locked to the screen like real play
// and counts frames that missed a screen refresh, which the player sees as a stutter.
BENCH_WARMUP_SECONDS :: 1.0
BENCH_SECONDS        :: 10.0

Frame_Sample :: struct {
	at, dt: f64,
}

Bench_Info :: struct {
	vsync:                          bool,
	refresh_rate, width, height:    int,
	chunks, meshed_chunks, sides:   int,
	drawn_total:                    int, // chunks drawn, summed over the measured frames
	generate_seconds, mesh_seconds: f64,
}

main :: proc() {
	bench_vsync := slice.contains(os.args, "--bench-vsync")
	bench := bench_vsync || slice.contains(os.args, "--bench")
	self_test := slice.contains(os.args, "--test")
	// Benchmarks and the self-test always start the same way, so they neither read nor change the settings.
	playing := !bench && !self_test
	path := settings_path()
	settings := settings_load(path) if playing else DEFAULT_SETTINGS

	if !glfw.Init() {
		fmt.eprintln("Could not start GLFW")
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)

	window := glfw.CreateWindow(settings.window_size.x, settings.window_size.y, GAME_NAME + " " + VERSION, nil, nil)
	if window == nil {
		fmt.eprintln("Could not open a window with OpenGL 3.3")
		return
	}
	defer glfw.DestroyWindow(window)
	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	if playing {
		glfw.SwapInterval(1)
		// Start as the remembered window, then switch to the remembered mode.
		glfw.SetWindowPos(window, settings.window_pos.x, settings.window_pos.y)
		start_mode := settings.display
		settings.display = .Windowed
		apply_display_mode(window, &settings, start_mode)
		if glfw.RawMouseMotionSupported() {
			glfw.SetInputMode(window, glfw.RAW_MOUSE_MOTION, 1)
		}
		glfw.SetScrollCallback(window, wheel_callback)
		// A key pressed and let go between two frames still counts once, so a quick tap of F3 or Esc
		// isn't lost, even during a slow frame.
		glfw.SetInputMode(window, glfw.STICKY_KEYS, 1)
	} else {
		// Measure at nearly full screen, the worst case for the graphics chip.
		glfw.MaximizeWindow(window)
		glfw.SwapInterval(1 if bench_vsync else 0)
	}

	renderer: Renderer
	ui: UI
	if !renderer_init(&renderer) || !ui_init(&ui, renderer.texture) {
		fmt.eprintln("Could not compile shaders")
		return
	}
	gpu := string(gl.GetString(gl.RENDERER))
	// Asking the system for the screen mode is slow, so it is asked once, not on every frame.
	refresh_rate := int(glfw.GetVideoMode(glfw.GetPrimaryMonitor()).refresh_rate)

	world: World
	info := Bench_Info{vsync = bench_vsync}
	start := glfw.GetTime()
	generate_planet(&world)
	generated := glfw.GetTime()
	info.sides, info.meshed_chunks = mesh_world(&world, &renderer)
	info.generate_seconds = generated - start
	info.mesh_seconds = glfw.GetTime() - generated
	info.chunks = len(world.chunks)

	if self_test {
		os.exit(0 if run_self_test(window, &renderer, &ui, &world) else 1)
	}

	player := spawn_player()
	camera := spawn_camera()
	keys := Key_State{last_jump_press = -1}
	hotbar := new_hotbar()
	looked_at: Ray_Hit
	break_down, place_down: bool
	break_timer, place_timer: f64
	paused := false
	// The benchmark keeps the F3 screen on, so its cost is part of the measurement.
	show_debug := bench
	escape_was_down, f11_was_down, f3_was_down, click_was_down: bool

	last_mouse_x, last_mouse_y := glfw.GetCursorPos(window)
	// While playing the mouse turns the view and its pointer is hidden; on pause the pointer comes back.
	// Coming back from pause, mouse buttons already held don't count as a click in the world.
	set_paused :: proc(window: glfw.WindowHandle, paused: bool, last_mouse_x, last_mouse_y: ^f64, break_down, place_down: ^bool) {
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_NORMAL if paused else glfw.CURSOR_DISABLED)
		if !paused {
			last_mouse_x^, last_mouse_y^ = glfw.GetCursorPos(window)
			break_down^, place_down^ = true, true
		}
	}
	if playing {
		set_paused(window, false, &last_mouse_x, &last_mouse_y, &break_down, &place_down)
	}

	last_time := glfw.GetTime()
	fps, fps_frames := 0, 0
	fps_timer := 0.0
	slowest_frame, worst_frame := 0.0, 0.0 // in this second so far, and in the last whole second

	bench_time := 0.0
	bench_frames: [dynamic]Frame_Sample
	defer delete(bench_frames)

	for !glfw.WindowShouldClose(window) {
		now := glfw.GetTime()
		dt := now - last_time
		last_time = now

		glfw.PollEvents()
		if bench {
			if key_down(window, glfw.KEY_ESCAPE) {
				break
			}
			bench_time += dt
			if bench_time > BENCH_WARMUP_SECONDS {
				append(&bench_frames, Frame_Sample{at = bench_time, dt = dt})
			}
			if bench_time >= BENCH_WARMUP_SECONDS + BENCH_SECONDS {
				break
			}
			bench_fly(&camera, bench_time)
		} else {
			escape, f11, f3 := key_down(window, glfw.KEY_ESCAPE), key_down(window, glfw.KEY_F11), key_down(window, glfw.KEY_F3)
			if escape && !escape_was_down {
				paused = !paused
				set_paused(window, paused, &last_mouse_x, &last_mouse_y, &break_down, &place_down)
			}
			if f11 && !f11_was_down {
				toggle_full_screen(window, &settings)
			}
			if f3 && !f3_was_down {
				show_debug = !show_debug
			}
			escape_was_down, f11_was_down, f3_was_down = escape, f11, f3
			// Like Minecraft: switching to another program pauses the game.
			if !paused && glfw.GetWindowAttrib(window, glfw.FOCUSED) == 0 {
				paused = true
				set_paused(window, paused, &last_mouse_x, &last_mouse_y, &break_down, &place_down)
			}
		}

		// Wheel turns made in the pause menu don't count once the game goes on.
		wheel := wheel_moved
		wheel_moved = 0

		if !bench && !paused {
			mouse_x, mouse_y := glfw.GetCursorPos(window)
			camera_turn(&camera, f32(mouse_x - last_mouse_x) * MOUSE_SENSITIVITY)
			camera.pitch -= f32(mouse_y - last_mouse_y) * MOUSE_SENSITIVITY
			camera.pitch = clamp(camera.pitch, -PITCH_LIMIT, PITCH_LIMIT)
			last_mouse_x, last_mouse_y = mouse_x, mouse_y
			// A long hitch (dragging the window) must not throw the player across the map.
			player_update(&world, &player, camera.heading, read_input(window, &keys), min(dt, 0.1))
			camera.pos = player_eye(player)
			camera_align(&camera)

			for slot in 0 ..< HOTBAR_SLOTS {
				if key_down(window, glfw.KEY_1 + i32(slot)) {
					hotbar_pick(&hotbar, slot, now)
				}
			}
			hotbar_scroll(&hotbar, wheel, now)
			looked_at = raycast(&world, camera.pos, look_direction(camera))
			breaking := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
			placing := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS
			if button_fires(breaking, &break_down, &break_timer, dt) && looked_at.hit {
				try_break(&world, &renderer, looked_at.block)
			}
			if button_fires(placing, &place_down, &place_timer, dt) && looked_at.hit {
				place_selected(&world, &renderer, player, looked_at.before, hotbar)
			}
			// Look again, so the outline already sits on what the edit left behind.
			looked_at = raycast(&world, camera.pos, look_direction(camera))
		}

		fps_frames += 1
		fps_timer += dt
		slowest_frame = max(slowest_frame, dt)
		if fps_timer >= 1 {
			fps = int(f64(fps_frames) / fps_timer + 0.5)
			worst_frame = slowest_frame
			fps_frames, fps_timer, slowest_frame = 0, 0, 0
		}

		target: Maybe(Block_Pos) = looked_at.block if looked_at.hit && !paused else nil
		drawn, ok := draw_frame(window, &renderer, &world, camera, target, playing && !paused)
		if !ok {
			// Minimized: sleep until something happens instead of spinning the CPU.
			glfw.WaitEvents()
			continue
		}
		if bench && bench_time > BENCH_WARMUP_SECONDS {
			info.drawn_total += drawn
		}

		click := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
		width, height := glfw.GetFramebufferSize(window)
		ui_begin(&ui, width, height, mouse_in_pixels(window), click && !click_was_down)
		hud_hotbar(&ui, hotbar, now)
		if show_debug {
			looking: Block = .Air
			if looked_at.hit {
				looking = world_get_block(&world, looked_at.block.face, looked_at.block.x, looked_at.block.y, looked_at.block.z)
			}
			debug_screen(&ui, Debug_Info {
				fps = fps,
				worst_frame = worst_frame,
				feet = camera.pos if bench else player.pos,
				heading = camera.heading,
				looking_at = looking,
				flying = player.flying,
				chunks_drawn = drawn,
				chunks_with_blocks = count_chunks_with_blocks(&world),
				screen = {width, height},
				refresh_rate = refresh_rate,
				gpu = gpu,
			})
		}
		// Over the hotbar and the F3 screen, which stay visible, dimmed, behind the menu.
		if paused {
			switch pause_menu(&ui, settings.display, fps, show_fps = !show_debug) {
			case .Resume:
				paused = false
				set_paused(window, paused, &last_mouse_x, &last_mouse_y, &break_down, &place_down)
			case .Next_Display_Mode:
				apply_display_mode(window, &settings, next_display_mode(settings.display))
			case .Quit:
				glfw.SetWindowShouldClose(window, true)
			case .None:
			}
		}
		ui_end(&ui)
		click_was_down = click

		glfw.SwapBuffers(window)
		free_all(context.temp_allocator)
	}

	if playing {
		remember_window(window, &settings)
		settings_save(path, settings)
	}
	if bench {
		width, height := glfw.GetFramebufferSize(window)
		info.width, info.height = int(width), int(height)
		info.refresh_rate = int(glfw.GetVideoMode(glfw.GetPrimaryMonitor()).refresh_rate)
		write_bench_report(bench_frames[:], info)
		save_bench_screenshots(window, &renderer, &world)
	}
}

// The mouse pointer in framebuffer pixels, from the top-left corner.
mouse_in_pixels :: proc(window: glfw.WindowHandle) -> [2]f32 {
	x, y := glfw.GetCursorPos(window)
	window_w, window_h := glfw.GetWindowSize(window)
	pixels_w, pixels_h := glfw.GetFramebufferSize(window)
	if window_w == 0 || window_h == 0 {
		return {}
	}
	return {f32(x) * f32(pixels_w) / f32(window_w), f32(y) * f32(pixels_h) / f32(window_h)}
}

// Standing on top of the column in the middle of the top face.
spawn_player :: proc() -> Player {
	MIDDLE :: FACE_BLOCKS / 2
	ground := terrain_column(.PY, MIDDLE, MIDDLE).height
	return Player{pos = face_to_world(.PY, MIDDLE + 0.5, MIDDLE + 0.5, f64(ground + 1))}
}

spawn_camera :: proc() -> Camera {
	return Camera{pos = player_eye(spawn_player()), heading = {0, 0, -1}, pitch = SPAWN_PITCH}
}

// Draws the world, an outline around the target block if there is one, and the crosshair if asked.
// Returns how many chunks were drawn; ok is false when the window is minimized and nothing was drawn.
draw_frame :: proc(window: glfw.WindowHandle, r: ^Renderer, w: ^World, cam: Camera, target: Maybe(Block_Pos) = nil, crosshair := false) -> (drawn: int, ok: bool) {
	width, height := glfw.GetFramebufferSize(window)
	if width == 0 || height == 0 {
		return 0, false
	}
	gl.Viewport(0, 0, width, height)
	gl.ClearColor(SPACE_COLOR.r, SPACE_COLOR.g, SPACE_COLOR.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	aspect := f32(width) / f32(height)
	projection := linalg.matrix4_perspective_f32(math.to_radians(f32(FOV_DEGREES)), aspect, NEAR_PLANE, FAR_PLANE)
	view_proj := projection * camera_view(cam)
	drawn = renderer_draw(r, w, view_proj, cam.pos)
	if pos, has_target := target.?; has_target {
		renderer_draw_outline(r, view_proj, pos, cam.pos)
	}
	if crosshair {
		renderer_draw_crosshair(r, width, height)
	}
	return drawn, true
}

key_down :: proc(window: glfw.WindowHandle, key: i32) -> bool {
	return glfw.GetKey(window, key) == glfw.PRESS
}

// W/S/A/D walk (or fly) relative to where you look, Space jumps (rises when flying), Shift sinks when flying,
// Ctrl runs, and a quick double tap of Space switches flying on or off.
read_input :: proc(window: glfw.WindowHandle, keys: ^Key_State) -> (input: Input) {
	if key_down(window, glfw.KEY_W) {input.move.y += 1}
	if key_down(window, glfw.KEY_S) {input.move.y -= 1}
	if key_down(window, glfw.KEY_D) {input.move.x += 1}
	if key_down(window, glfw.KEY_A) {input.move.x -= 1}
	input.jump = key_down(window, glfw.KEY_SPACE)
	input.descend = key_down(window, glfw.KEY_LEFT_SHIFT)
	input.sprint = key_down(window, glfw.KEY_LEFT_CONTROL)
	input.toggle_fly = jump_double_tap(keys, input.jump, glfw.GetTime())
	return
}

// True on the press that comes within DOUBLE_TAP_SECONDS of the previous one.
// A third quick press starts a new pair instead of switching back straight away.
jump_double_tap :: proc(keys: ^Key_State, down: bool, now: f64) -> (toggle: bool) {
	if down && !keys.jump_was_down {
		if keys.last_jump_press >= 0 && now - keys.last_jump_press < DOUBLE_TAP_SECONDS {
			toggle = true
			keys.last_jump_press = -1
		} else {
			keys.last_jump_press = now
		}
	}
	keys.jump_was_down = down
	return
}

// One full lap along a tilted circle above the highest peaks, so the flight crosses several faces and seams.
bench_fly :: proc(cam: ^Camera, t: f64) {
	angle := t / (BENCH_WARMUP_SECONDS + BENCH_SECONDS) * 2 * math.PI
	a := [3]f64{1, 0, 0}
	b := linalg.normalize([3]f64{0, 0.6, 0.8})
	cam.pos = (a * math.cos(angle) + b * math.sin(angle)) * (PLANET_RADIUS + MAX_HEIGHT + 8)
	cam.heading = ([3]f32)(b * math.cos(angle) - a * math.sin(angle))
	cam.pitch = -0.35
	camera_align(cam)
}

write_bench_report :: proc(frames: []Frame_Sample, info: Bench_Info) {
	if len(frames) == 0 {
		return
	}
	slowest_first := slice.clone(frames, context.temp_allocator)
	slice.sort_by(slowest_first, proc(a, b: Frame_Sample) -> bool {return a.dt > b.dt})

	total := 0.0
	for f in frames {
		total += f.dt
	}
	// "1% low" is the average FPS over the slowest 1% of frames: it shows stutter that the average hides.
	slow_count := max(1, len(frames) / 100)
	slow_total := 0.0
	for f in slowest_first[:slow_count] {
		slow_total += f.dt
	}
	worst := slowest_first[0].dt

	// With vsync a frame that takes 1.5 refreshes or more means a refresh showed the old picture again.
	// Without vsync the bar is simply 60 FPS.
	limit := 1.5 / f64(info.refresh_rate) if info.vsync else 1.0 / 60
	over_limit := 0
	for f in frames {
		if f.dt > limit {
			over_limit += 1
		}
	}

	slowest_list := strings.builder_make(context.temp_allocator)
	for f in slowest_first[:min(5, len(slowest_first))] {
		fmt.sbprintf(&slowest_list, " %.1fms@%.2fs", f.dt * 1000, f.at)
	}

	report := fmt.tprintf(
		"%s %s benchmark\n" +
		"gpu: %s\n" +
		"resolution: %dx%d, vsync %s, screen %d Hz\n" +
		"world: %d chunks, %d block sides, built in %.2f s (generate %.2f + mesh %.2f)\n" +
		"drawn per frame: %d of %d chunks that have blocks to show\n" +
		"frames: %d in %.1f s\n" +
		"average FPS: %.0f\n" +
		"1%% low FPS: %.0f\n" +
		"worst frame: %.2f ms (%.0f FPS)\n" +
		"frames over %.1f ms: %d\n" +
		"slowest frames:%s\n",
		GAME_NAME, VERSION,
		gl.GetString(gl.RENDERER),
		info.width, info.height, "on" if info.vsync else "off", info.refresh_rate,
		info.chunks, info.sides, info.generate_seconds + info.mesh_seconds, info.generate_seconds, info.mesh_seconds,
		info.drawn_total / len(frames), info.meshed_chunks,
		len(frames), total,
		f64(len(frames)) / total,
		f64(slow_count) / slow_total,
		worst * 1000, 1 / worst,
		limit * 1000, over_limit,
		strings.to_string(slowest_list),
	)
	if err := os.write_entire_file("bench.txt", report); err != nil {
		fmt.eprintln("Could not write bench.txt:", err)
	}
	fmt.print(report)
}

// Fixed views saved as bench_1.png, bench_2.png, ... so every version can be checked by eye.
save_bench_screenshots :: proc(window: glfw.WindowHandle, r: ^Renderer, w: ^World) {
	look_from :: proc(pos, target: [3]f64) -> Camera {
		cam := Camera{pos = pos}
		camera_look_at(&cam, target)
		return cam
	}
	// A cube corner, where three faces and three seams meet.
	corner := linalg.normalize([3]f64{1, 1, 1})
	peak := w.highest_point
	up := linalg.normalize(peak)
	beside := linalg.normalize(linalg.cross(up, [3]f64{0, 0, 1} if abs(up.z) < 0.9 else [3]f64{1, 0, 0}))
	shots := [?]Camera {
		spawn_camera(),                                               // what the player sees on start
		look_from(corner * (PLANET_RADIUS + 350), {0, 0, 0}),         // the whole planet from far away
		look_from(peak + up * 6 + beside * 45, peak - up * 12),       // the tallest mountain up close
		look_from(peak + up * 60 + beside * 110, peak - up * 10),     // its mountain range from above
	}
	for shot, i in shots {
		if _, ok := draw_frame(window, r, w, shot); !ok {
			return
		}
		save_screenshot(window, fmt.ctprintf("bench_%d.png", i + 1))
		glfw.SwapBuffers(window)
	}
}

save_screenshot :: proc(window: glfw.WindowHandle, path: cstring) {
	width, height := glfw.GetFramebufferSize(window)
	pixels := make([]u8, int(width * height * 4), context.temp_allocator)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	// OpenGL's first row is the bottom of the screen; PNG's is the top.
	stbi.flip_vertically_on_write(true)
	stbi.write_png(path, width, height, 4, raw_data(pixels), width * 4)
}
