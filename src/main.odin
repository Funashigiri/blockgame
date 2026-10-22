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
VERSION   :: "0.0.3"

WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

SPACE_COLOR :: [3]f32{0.01, 0.01, 0.025}

// Start above the middle of the top face, this high above the ground, looking out toward the horizon.
SPAWN_ALTITUDE :: 30.0
SPAWN_PITCH    :: -0.45

FOV_DEGREES       :: 70.0
NEAR_PLANE        :: 0.05
FAR_PLANE         :: 2000.0
FLY_SPEED         :: 11.0 // blocks per second
SPRINT_MULTIPLIER :: 2.5
MOUSE_SENSITIVITY :: 0.0022 // radians per pixel

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
	info := Bench_Info{vsync = bench_vsync}
	start := glfw.GetTime()
	generate_planet(&world)
	generated := glfw.GetTime()
	info.sides, info.meshed_chunks = mesh_world(&world, &renderer)
	info.generate_seconds = generated - start
	info.mesh_seconds = glfw.GetTime() - generated
	info.chunks = len(world.chunks)

	camera := spawn_camera()

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
			bench_fly(&camera, bench_time)
		} else {
			mouse_x, mouse_y := glfw.GetCursorPos(window)
			camera_turn(&camera, f32(mouse_x - last_mouse_x) * MOUSE_SENSITIVITY)
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

		drawn, ok := draw_frame(window, &renderer, &world, camera)
		if !ok {
			// Minimized: sleep until something happens instead of spinning the CPU.
			glfw.WaitEvents()
			continue
		}
		if bench && bench_time > BENCH_WARMUP_SECONDS {
			info.drawn_total += drawn
		}
		glfw.SwapBuffers(window)
		free_all(context.temp_allocator)
	}

	if bench {
		width, height := glfw.GetFramebufferSize(window)
		info.width, info.height = int(width), int(height)
		info.refresh_rate = int(glfw.GetVideoMode(glfw.GetPrimaryMonitor()).refresh_rate)
		write_bench_report(bench_frames[:], info)
		save_bench_screenshots(window, &renderer, &world)
	}
}

spawn_camera :: proc() -> Camera {
	MIDDLE :: FACE_BLOCKS / 2
	ground := terrain_column(.PY, MIDDLE, MIDDLE).height
	pos := face_to_world(.PY, MIDDLE, MIDDLE, f64(ground) + SPAWN_ALTITUDE)
	return Camera{pos = pos, heading = {0, 0, -1}, pitch = SPAWN_PITCH}
}

// Returns how many chunks were drawn; ok is false when the window is minimized and nothing was drawn.
draw_frame :: proc(window: glfw.WindowHandle, r: ^Renderer, w: ^World, cam: Camera) -> (drawn: int, ok: bool) {
	width, height := glfw.GetFramebufferSize(window)
	if width == 0 || height == 0 {
		return 0, false
	}
	gl.Viewport(0, 0, width, height)
	gl.ClearColor(SPACE_COLOR.r, SPACE_COLOR.g, SPACE_COLOR.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	aspect := f32(width) / f32(height)
	projection := linalg.matrix4_perspective_f32(math.to_radians(f32(FOV_DEGREES)), aspect, NEAR_PLANE, FAR_PLANE)
	return renderer_draw(r, w, projection * camera_view(cam), cam.pos), true
}

key_down :: proc(window: glfw.WindowHandle, key: i32) -> bool {
	return glfw.GetKey(window, key) == glfw.PRESS
}

// Creative-style flight around the planet: W/S/A/D move along the ground relative to where you look,
// Space/Shift go straight up/down. Moving along the ground keeps your height, so W alone circles the planet.
fly_controls :: proc(window: glfw.WindowHandle, cam: ^Camera, dt: f32) {
	along: [3]f32
	vertical: f32
	if key_down(window, glfw.KEY_W) {along += cam.heading}
	if key_down(window, glfw.KEY_S) {along -= cam.heading}
	if key_down(window, glfw.KEY_D) {along += camera_right(cam^)}
	if key_down(window, glfw.KEY_A) {along -= camera_right(cam^)}
	if key_down(window, glfw.KEY_SPACE) {vertical += 1}
	if key_down(window, glfw.KEY_LEFT_SHIFT) {vertical -= 1}
	if along == 0 && vertical == 0 {
		return
	}
	speed: f32 = FLY_SPEED
	if key_down(window, glfw.KEY_LEFT_CONTROL) {
		speed *= SPRINT_MULTIPLIER
	}
	// Divide by the length of the whole move, so diagonal flight isn't faster.
	step := speed * dt / math.sqrt(linalg.dot(along, along) + vertical * vertical)
	radius := linalg.length(cam.pos)
	cam.pos += ([3]f64)(along * step)
	cam.pos = linalg.normalize(cam.pos) * max(radius + f64(vertical * step), 1)
	camera_align(cam)
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
