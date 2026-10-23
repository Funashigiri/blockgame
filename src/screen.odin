package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "vendor:glfw"

Display_Mode :: enum {
	Windowed,   // a normal window with a frame, can be moved and resized
	Borderless, // a frameless window covering the whole screen: looks full screen, Alt+Tab is instant
	Fullscreen, // the game takes over the screen
}

@(rodata)
DISPLAY_MODE_NAMES := [Display_Mode]string {
	.Windowed   = "в окне",
	.Borderless = "окно без рамки",
	.Fullscreen = "полный экран",
}

@(rodata)
DISPLAY_MODE_KEYS := [Display_Mode]string {
	.Windowed   = "windowed",
	.Borderless = "borderless",
	.Fullscreen = "fullscreen",
}

// Remembered between runs.
Settings :: struct {
	display:         Display_Mode,
	last_full:       Display_Mode, // what F11 switches to from a window
	window_pos:      [2]i32,       // the window's place and size, to come back to after full screen
	window_size:     [2]i32,
	sensitivity:     int,  // mouse look speed, percent of the standard
	fov:             int,  // field of view, degrees from the top of the screen to the bottom
	vsync:           bool, // frames wait for the screen's refresh: no tearing, FPS capped at the refresh rate
	render_distance: int,  // in chunks
}

SENSITIVITY_RANGE     :: [2]int{10, 200}
FOV_RANGE             :: [2]int{30, 110}
RENDER_DISTANCE_RANGE :: [2]int{2, 32}

// The whole small planet is in view at the longest render distance, so that is where it starts.
DEFAULT_SETTINGS :: Settings {
	display         = .Windowed,
	last_full       = .Fullscreen,
	window_pos      = {100, 100},
	window_size     = {WINDOW_WIDTH, WINDOW_HEIGHT},
	sensitivity     = 100,
	fov             = 70,
	vsync           = true,
	render_distance = 32,
}

// %APPDATA%\blockgame\settings.txt, where Windows programs keep their settings.
// Kept for the whole run (the temporary allocator is cleared every frame).
settings_path :: proc() -> string {
	appdata := os.get_env("APPDATA", context.temp_allocator)
	if appdata == "" {
		return "settings.txt"
	}
	return fmt.aprintf("%s\\%s\\settings.txt", appdata, GAME_NAME)
}

// Plain "key=value" lines; anything missing or unreadable keeps its default.
settings_load :: proc(path: string) -> Settings {
	s := DEFAULT_SETTINGS
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return s
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		key, _, value := strings.partition(strings.trim_space(line), "=")
		switch key {
		case "display":
			s.display = display_mode_from_key(value, s.display)
		case "last_full":
			s.last_full = display_mode_from_key(value, s.last_full)
		case "window":
			numbers: [4]i32
			count := 0
			for field in strings.fields(value, context.temp_allocator) {
				if n, ok := strconv.parse_int(field); ok && count < 4 {
					numbers[count] = i32(n)
					count += 1
				}
			}
			if count == 4 && numbers[2] > 0 && numbers[3] > 0 {
				s.window_pos, s.window_size = {numbers[0], numbers[1]}, {numbers[2], numbers[3]}
			}
		case "sensitivity":
			s.sensitivity = setting_number(value, s.sensitivity, SENSITIVITY_RANGE)
		case "fov":
			s.fov = setting_number(value, s.fov, FOV_RANGE)
		case "render_distance":
			s.render_distance = setting_number(value, s.render_distance, RENDER_DISTANCE_RANGE)
		case "vsync":
			if value == "on" || value == "off" {
				s.vsync = value == "on"
			}
		}
	}
	return s
}

// A whole number kept inside its range; anything unreadable keeps the fallback.
setting_number :: proc(text: string, fallback: int, range: [2]int) -> int {
	if n, ok := strconv.parse_int(text); ok {
		return clamp(n, range[0], range[1])
	}
	return fallback
}

display_mode_from_key :: proc(key: string, fallback: Display_Mode) -> Display_Mode {
	for mode in Display_Mode {
		if DISPLAY_MODE_KEYS[mode] == key {
			return mode
		}
	}
	return fallback
}

settings_save :: proc(path: string, s: Settings) {
	if dir := filepath.dir(path); dir != "." {
		_ = os.make_directory_all(dir)
	}
	text := fmt.tprintf("display=%s\nlast_full=%s\nwindow=%d %d %d %d\nsensitivity=%d\nfov=%d\nvsync=%s\nrender_distance=%d\n",
		DISPLAY_MODE_KEYS[s.display], DISPLAY_MODE_KEYS[s.last_full],
		s.window_pos.x, s.window_pos.y, s.window_size.x, s.window_size.y,
		s.sensitivity, s.fov, "on" if s.vsync else "off", s.render_distance)
	if err := os.write_entire_file(path, text); err != nil {
		fmt.eprintln("Could not save settings:", err)
	}
}

// Switches the window between the three display modes, keeping the windowed place and size
// so that coming back to a window puts it where it was.
apply_display_mode :: proc(window: glfw.WindowHandle, s: ^Settings, mode: Display_Mode) {
	remember_window(window, s)
	monitor := glfw.GetPrimaryMonitor()
	video := glfw.GetVideoMode(monitor)
	monitor_x, monitor_y := glfw.GetMonitorPos(monitor)
	switch mode {
	case .Windowed:
		// Keep the title bar on the screen, in case the screen setup changed since last time.
		area_x, area_y, area_w, area_h := glfw.GetMonitorWorkarea(monitor)
		x := clamp(s.window_pos.x, area_x, max(area_x, area_x + area_w - s.window_size.x))
		y := clamp(s.window_pos.y, area_y + 30, max(area_y + 30, area_y + area_h - s.window_size.y))
		// Leave full screen first, then put the frame back, then place the window: the frame changes its size.
		glfw.SetWindowMonitor(window, nil, x, y, s.window_size.x, s.window_size.y, 0)
		glfw.SetWindowAttrib(window, glfw.DECORATED, 1)
		glfw.SetWindowMonitor(window, nil, x, y, s.window_size.x, s.window_size.y, 0)
	case .Borderless:
		glfw.SetWindowMonitor(window, nil, monitor_x, monitor_y, video.width, video.height, 0)
		glfw.SetWindowAttrib(window, glfw.DECORATED, 0)
		glfw.SetWindowMonitor(window, nil, monitor_x, monitor_y, video.width, video.height, 0)
	case .Fullscreen:
		glfw.SetWindowMonitor(window, monitor, 0, 0, video.width, video.height, video.refresh_rate)
	}
	if mode != .Windowed {
		s.last_full = mode
	}
	s.display = mode
	// Some drivers forget the frame-rate lock when the window changes monitor or size.
	apply_vsync(s^)
}

apply_vsync :: proc(s: Settings) {
	glfw.SwapInterval(1 if s.vsync else 0)
}

// How far the view turns per pixel of mouse movement.
look_speed :: proc(s: Settings) -> f32 {
	return MOUSE_SENSITIVITY * f32(s.sensitivity) / 100
}

// Notes where the window is and how big, while it is an ordinary window.
remember_window :: proc(window: glfw.WindowHandle, s: ^Settings) {
	if s.display == .Windowed && glfw.GetWindowMonitor(window) == nil && glfw.GetWindowAttrib(window, glfw.DECORATED) != 0 {
		x, y := glfw.GetWindowPos(window)
		w, h := glfw.GetWindowSize(window)
		if w > 0 && h > 0 {
			s.window_pos, s.window_size = {x, y}, {w, h}
		}
	}
}

// F11: from a window to the last full-screen kind used, and back.
toggle_full_screen :: proc(window: glfw.WindowHandle, s: ^Settings) {
	apply_display_mode(window, s, s.last_full if s.display == .Windowed else .Windowed)
}

next_display_mode :: proc(mode: Display_Mode) -> Display_Mode {
	return Display_Mode((int(mode) + 1) % len(Display_Mode))
}
