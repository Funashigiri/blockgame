package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
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

feet_layer :: proc(p: Player) -> f64 {
	_, grid := world_to_face(p.pos)
	return grid.y
}

run_self_test :: proc(window: glfw.WindowHandle, r: ^Renderer, w: ^World) -> bool {
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
			if _, ok := draw_frame(window, r, w, cam); ok {
				save_screenshot(window, fmt.ctprintf("test_%d.png", shots))
				glfw.SwapBuffers(window)
			}
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

	fmt.sbprintf(&log.text, "\n%s\n", "ALL PASSED" if log.failed == 0 else fmt.tprintf("%d FAILED", log.failed))
	report := strings.to_string(log.text)
	if err := os.write_entire_file("test.txt", report); err != nil {
		fmt.eprintln("Could not write test.txt:", err)
	}
	fmt.print(report)
	return log.failed == 0
}
