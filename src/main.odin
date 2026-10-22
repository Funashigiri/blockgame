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
VERSION   :: "0.0.1"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

SKY_COLOR :: [3]f32{0.47, 0.65, 1.0}

// Start just off the island's rim, a little above it, looking at its centre.
SPAWN_POS     :: [3]f32{0, ISLAND_TOP + 10, ISLAND_RADIUS + 14}
SPAWN_LOOK_AT :: [3]f32{0, ISLAND_TOP, 0}

FOV_DEGREES       :: 70.0
NEAR_PLANE        :: 0.05
FAR_PLANE         :: 1000.0
FLY_SPEED         :: 11.0 // blocks per second
SPRINT_MULTIPLIER :: 2.5
MOUSE_SENSITIVITY :: 0.0022 // radians per pixel

// --bench flies a fixed circle around the island and writes bench.txt.
// Without a frame cap it shows the headroom; --bench-vsync runs locked to the screen like real play
// and counts frames that missed a screen refresh, which the player sees as a stutter.
BENCH_WARMUP_SECONDS :: 1.0
BENCH_SECONDS        :: 10.0

Frame_Sample :: struct {
	at, dt: f64,
}

main :: proc() {
	bench_vsync := slice.contains(os.args, "--bench-vsync")
	bench := bench_vsync || slice.contains(os.args, "--bench")

	if !glfw.Init() {
		fmt.eprintln("Could not start GLFW")
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)

	window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, GAME_NAME + " " + VERSION, nil, nil)
	if window == nil {
		fmt.eprintln("Could not open a window with OpenGL 3.3")
		return
	}
	defer glfw.DestroyWindow(window)
	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	if bench {
		// Measure at nearly full screen, the worst case for the graphics chip.
		glfw.MaximizeWindow(window)
		glfw.SwapInterval(1 if bench_vsync else 0)
	} else {
		glfw.SwapInterval(1)
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		if glfw.RawMouseMotionSupported() {
			glfw.SetInputMode(window, glfw.RAW_MOUSE_MOTION, 1)
		}
	}

	renderer: Renderer
	if !renderer_init(&renderer) {
		fmt.eprintln("Could not compile shaders")
		return
	}

	world: World
	generate_island(&world)
	face_count := mesh_world(&world, &renderer)

	camera := Camera{pos = SPAWN_POS}
	camera_look_at(&camera, SPAWN_LOOK_AT)

	last_mouse_x, last_mouse_y := glfw.GetCursorPos(window)
	last_time := glfw.GetTime()
	fps_frames := 0
	fps_timer := 0.0

	bench_time := 0.0
	bench_frames: [dynamic]Frame_Sample
	defer delete(bench_frames)

	for !glfw.WindowShouldClose(window) {
		now := glfw.GetTime()
		dt := now - last_time
		last_time = now

		glfw.PollEvents()
		if key_down(window, glfw.KEY_ESCAPE) {
			glfw.SetWindowShouldClose(window, true)
		}

		if bench {
			bench_time += dt
			if bench_time > BENCH_WARMUP_SECONDS {
				append(&bench_frames, Frame_Sample{at = bench_time, dt = dt})
			}
			if bench_time >= BENCH_WARMUP_SECONDS + BENCH_SECONDS {
				break
			}
			bench_fly(&camera, f32(bench_time))
		} else {
			mouse_x, mouse_y := glfw.GetCursorPos(window)
			camera.yaw += f32(mouse_x - last_mouse_x) * MOUSE_SENSITIVITY
			camera.pitch -= f32(mouse_y - last_mouse_y) * MOUSE_SENSITIVITY
			camera.pitch = clamp(camera.pitch, -PITCH_LIMIT, PITCH_LIMIT)
			last_mouse_x, last_mouse_y = mouse_x, mouse_y
			// A long hitch (dragging the window) must not throw the player across the map.
			fly_controls(window, &camera, f32(min(dt, 0.1)))
		}

		fps_frames += 1
		fps_timer += dt
		if fps_timer >= 1 {
			fps := int(f64(fps_frames) / fps_timer + 0.5)
			glfw.SetWindowTitle(window, fmt.ctprintf("%s %s | %d FPS", GAME_NAME, VERSION, fps))
			fps_frames = 0
			fps_timer = 0
		}

		if !draw_frame(window, &renderer, &world, camera) {
			// Minimized: sleep until something happens instead of spinning the CPU.
			glfw.WaitEvents()
			continue
		}
		glfw.SwapBuffers(window)
		free_all(context.temp_allocator)
	}

	if bench {
		width, height := glfw.GetFramebufferSize(window)
		refresh_rate := int(glfw.GetVideoMode(glfw.GetPrimaryMonitor()).refresh_rate)
		write_bench_report(bench_frames[:], bench_vsync, refresh_rate, int(width), int(height), len(world.chunks), face_count)
		save_bench_screenshots(window, &renderer, &world)
	}
}

draw_frame :: proc(window: glfw.WindowHandle, r: ^Renderer, w: ^World, cam: Camera) -> bool {
	width, height := glfw.GetFramebufferSize(window)
	if width == 0 || height == 0 {
		return false
	}
	gl.Viewport(0, 0, width, height)
	gl.ClearColor(SKY_COLOR.r, SKY_COLOR.g, SKY_COLOR.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	aspect := f32(width) / f32(height)
	projection := linalg.matrix4_perspective_f32(math.to_radians(f32(FOV_DEGREES)), aspect, NEAR_PLANE, FAR_PLANE)
	renderer_draw_world(r, w, projection * camera_view(cam))
	return true
}

key_down :: proc(window: glfw.WindowHandle, key: i32) -> bool {
	return glfw.GetKey(window, key) == glfw.PRESS
}

// Creative-style flight: W/S/A/D move flat relative to where you look, Space/Shift go straight up/down.
fly_controls :: proc(window: glfw.WindowHandle, cam: ^Camera, dt: f32) {
	forward := [3]f32{math.sin(cam.yaw), 0, -math.cos(cam.yaw)}
	right := [3]f32{math.cos(cam.yaw), 0, math.sin(cam.yaw)}
	move: [3]f32
	if key_down(window, glfw.KEY_W) {move += forward}
	if key_down(window, glfw.KEY_S) {move -= forward}
	if key_down(window, glfw.KEY_D) {move += right}
	if key_down(window, glfw.KEY_A) {move -= right}
	if key_down(window, glfw.KEY_SPACE) {move.y += 1}
	if key_down(window, glfw.KEY_LEFT_SHIFT) {move.y -= 1}
	if move == 0 {
		return
	}
	speed: f32 = FLY_SPEED
	if key_down(window, glfw.KEY_LEFT_CONTROL) {
		speed *= SPRINT_MULTIPLIER
	}
	cam.pos += linalg.normalize(move) * speed * dt
}

// One full circle around the island over the whole benchmark, always looking at its centre.
bench_fly :: proc(cam: ^Camera, t: f32) {
	angle := t / (BENCH_WARMUP_SECONDS + BENCH_SECONDS) * 2 * math.PI
	cam.pos = {math.sin(angle) * 55, ISLAND_TOP + 14, math.cos(angle) * 55}
	camera_look_at(cam, {0, ISLAND_TOP, 0})
}

write_bench_report :: proc(frames: []Frame_Sample, vsync: bool, refresh_rate, width, height, chunks, faces: int) {
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
	limit := 1.5 / f64(refresh_rate) if vsync else 1.0 / 60
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
		"world: %d chunks, %d faces\n" +
		"frames: %d in %.1f s\n" +
		"average FPS: %.0f\n" +
		"1%% low FPS: %.0f\n" +
		"worst frame: %.2f ms (%.0f FPS)\n" +
		"frames over %.1f ms: %d\n" +
		"slowest frames:%s\n",
		GAME_NAME, VERSION,
		gl.GetString(gl.RENDERER),
		width, height, "on" if vsync else "off", refresh_rate,
		chunks, faces,
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
	Shot :: struct {
		pos, target: [3]f32,
	}
	shots := [?]Shot {
		{SPAWN_POS, SPAWN_LOOK_AT},                                       // what the player sees on start
		{{30, ISLAND_TOP - 25, 60}, {0, ISLAND_TOP - 5, 0}},              // underside of the island
		{{0, ISLAND_TOP + 3, 44}, {0, ISLAND_TOP - 1, 33}},               // close-up of the grass edge
	}
	for shot, i in shots {
		cam := Camera{pos = shot.pos}
		camera_look_at(&cam, shot.target)
		if !draw_frame(window, r, w, cam) {
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
