# I, Voyager Assistant — Specification

## 1. Purpose

The Assistant plugin provides a programmatic interface to the I, Voyager simulation with two goals:

1. **AI-assisted testing** — Enable AI tools (Claude Code) to query simulation state and exercise controls, verifying correctness of orbital mechanics, scene tree construction, time management, and GUI behavior.
2. **Accessibility** — Provide a command-based interface that can be driven by voice control, screen readers, or other assistive technologies for solar system navigation.

## 2. Architecture

### 2.1 Integration with Core

The plugin integrates via the Godot EditorPlugin system:

- **EditorPlugin** — Registers `IVAssistantServer` as an autoload via `add_autoload_singleton()` when the plugin is enabled, and removes it when disabled.
- **IVAssistantServer** — An autoload Node (root-level singleton). Reads config in `_ready()`, then loads test suites and starts a TCP server on `core_initialized`, and forwards lifecycle events to suites on `simulator_started`. Processes commands in `_process()` on the main thread. Inert in a web export, which has no `TCPServer`.
- **IVAssistantTestSuite** — RefCounted base class for test suites. Each suite registers method names and handles dispatch. Suites are loaded from the `[assistant_test_suites]` config section and can be added, replaced, or removed via override config files.

### 2.2 Component Diagram

```
EditorPlugin (editor/editor_plugin.gd)
  └─ _enter_tree(): reads ivoyager_assistant.cfg, calls add_autoload_singleton()

IVAssistantServer (autoload Node, root-level singleton)
  ├─ _ready(): reads config and command-line args, checks enabled/debug_only, connects signals
  ├─ on core_initialized: loads test suites, starts TCPServer on 127.0.0.1:<port> (§7.3)
  ├─ on simulator_started: forwards to all test suites, re-evaluates method gating
  └─ _process(): polls TCP, reads JSON commands, dispatches, writes JSON responses
	   ├─ built-in: get_project_info, get_state, start_game, quit
	   └─ delegates to test suites for all other methods

IVAssistantTestSuite (RefCounted base class; default suites and methods in §7.2)
  ├─ StateQuerySuite: time, selection, camera and body queries
  ├─ ControlSuite: selection, pause, speed, time, camera, GUI, HUDs, actions
  ├─ ViewSuite: built-in and user-cached views
  ├─ SettingsSuite: user settings
  ├─ CoreTestSuite: screenshot, save/load
  ├─ GuiInspectionSuite: find_nodes, inspect_node, read_node_text
  ├─ MouseTargetIdSuite: warp_mouse, project_to_screen, get_hover_target
  └─ SmallBodiesIdSuite: small-body group listing, projection and visibility
```

### 2.3 Lifecycle

1. EditorPlugin registers `IVAssistantServer` as an autoload when the plugin is enabled
2. On game start, `IVAssistantServer._ready()` reads config and command-line overrides (§7.3), checks `enabled`/`debug_only`, connects to `IVStateManager` signals
3. On `core_initialized`: test suites load from the `[assistant_test_suites]` config section and their requirement tokens resolve (§7.5); the TCP server starts listening. Only built-in methods (`get_project_info`, `get_state`, `start_game`, `quit`) and test suite methods that don't require sim started (e.g. `get_save_status`, `get_options`) are available
4. On `simulator_started`: forwarded to all test suites so they can cache program references, and `widget.*` / `runtime.*` requirement tokens are re-evaluated. The readiness gate begins evaluating each frame.
5. **Readiness gate opens** after the project-supplied `ready_predicate` (default trivially true) has returned `true` for `min_ready_delay_frames` consecutive frames (default 10). Sim-gated API methods become available only at this point. See §7.3 and §7.4.
6. On `about_to_free_procedural_nodes`: forwarded to all test suites to clear references, sim-dependent methods return errors. The readiness gate re-arms (closes until the next `simulator_started` plus delay).
7. On `about_to_quit`: TCP server shuts down

For projects with `wait_for_start = true` (splash screens), there is a gap between steps 3 and 4 during which the client can connect, query project info, and call `start_game` to bypass the splash screen.

### 2.4 Security

- TCP server binds to `127.0.0.1` only (localhost)
- Server starts only when `OS.is_debug_build()` is true, unless overridden in config
- No authentication (localhost-only, debug-only)

## 3. Communication Protocol

### 3.1 Transport

- **TCP** on `localhost`, default port `29071`
- Port configurable via `ivoyager_assistant.cfg` under `[assistant]` section, or per process on the command line (§7.3), so several instances can run on one machine

### 3.2 Message Format

Newline-delimited JSON. Each message is a single line terminated by `\n`.

**Request:**
```json
{"id": 1, "method": "get_state", "params": {}}
```

**Success response:**
```json
{"id": 1, "result": {...}}
```

**Error response:**
```json
{"id": 1, "error": {"code": 1, "message": "Unknown method"}}
```

- `id` — Integer, echoed back to match request/response pairs. Optional; if omitted, response has no `id`.
- `method` — String, the API method name.
- `params` — Dictionary, method-specific parameters. Optional; defaults to `{}`.

### 3.3 Error Codes

| Code | Meaning |
|------|---------|
| 1 | Unknown method |
| 2 | Invalid parameters |
| 3 | Body not found |
| 4 | Simulator not ready (not started, or readiness gate not yet open) |
| 5 | Operation not allowed |

## 4. API Methods

### 4.0 Project Info (available before simulator starts)

#### `get_project_info`
Returns project identity, configuration, available capabilities, and optional context. Available as soon as TCP server starts (before `simulator_started`).

**Params:** none

**Result:**
```json
{
  "assistant_protocol_version": 3,
  "project_name": "I Voyager Planetarium",
  "project_version": "0.0.20",
  "assistant_name": "I Voyager Planetarium",
  "started": true,
  "ok_to_start": false,
  "wait_for_start": false,
  "allow_time_setting": true,
  "capabilities": ["get_state", "get_time", "list_bodies", "..."],
  "methods": {"get_time": {}, "list_views": {"summary": "..."}, "...": {}},
  "gated_out": [{"method": "get_save_status", "unmet": ["autoload.IVSave"]}],
  "process_id": 12345,
  "port": 29071,
  "instance_id": "run-a"
}
```

- `assistant_name` defaults to `project_name` unless overridden in config.
- `capabilities`, `methods` and `gated_out` describe which methods are available and why others are not (§8.1).
- `context` (string, optional) included if a context file is configured.
- `process_id` (int) is the game's OS process id — on Windows the game's own process, not the `_console.exe` wrapper a launcher starts — and `port` the port it listens on.
- `instance_id` (string, optional) echoes the `--assistant-instance` command-line argument (§7.3). A launcher that passes one can confirm it reached the process it started rather than another instance holding the port.

#### `start_game`
Start the simulation in projects with splash screens (`wait_for_start = true`). Returns error if already started or not ready (assets still loading).

**Params:** none

**Result:** `{"ok": true}`

#### `quit`
Shut down the application.

**Params:**
- `force` (bool, optional, default `false`) — If `true`, quit immediately without confirmation dialog. If `false`, may trigger a "Quit without saving?" dialog in projects that use one.

**Result:** `{"ok": true}`

Note: Response is sent before quit executes (via `call_deferred`).

### 4.1 State Queries

#### `get_state`
Returns overall simulation state. If the Save plugin is present, includes `is_saving` and `is_loading` fields.

**Params:** none

**Result:**
```json
{
  "started": true,
  "running": true,
  "paused_tree": false,
  "paused_by_user": false,
  "building_system": false,
  "time": 7.889e8,
  "date": [2025, 1, 15],
  "clock": [14, 30, 0],
  "speed_index": 0,
  "speed_name": "1x",
  "reversed_time": false,
  "is_saving": false,
  "is_loading": false
}
```

`is_saving` and `is_loading` are only present when the IVSave plugin is enabled.

#### `get_time`
Returns detailed time information.

**Params:** none

**Result:**
```json
{
  "time": 7.889e8,
  "date": [2025, 1, 15],
  "clock": [14, 30, 0],
  "julian_day_number": 2460690,
  "speed_multiplier": 1.0,
  "speed_index": 0,
  "speed_name": "1x",
  "reversed_time": false
}
```

#### `get_selection`
Returns the current GUI selection.

**Params:** none

**Result:**
```json
{
  "name": "PLANET_EARTH",
  "gui_name": "Earth",
  "is_body": true,
  "body_flags": 1048
}
```

#### `get_camera`
Returns camera state.

**Params:** none

**Result:**
```json
{
  "target": "PLANET_EARTH",
  "flags": 9,
  "view_position": [5.0, 0.3, 1.2],
  "view_rotations": [0.0, 0.0, 0.0],
  "is_camera_lock": true
}
```

`flags` is the `IVCamera.CameraFlags` bitmask, which carries the tracking mode and up-lock (9 is up-locked, orbit tracking). `view_position` is in the frame that tracking mode names (see `move_camera`).

#### `list_bodies`
Lists celestial bodies in the simulation.

**Params:**
- `filter` (string, optional) — `"all"`, `"stars"`, `"planets"`, `"dwarf_planets"`, `"moons"`, `"spacecraft"`. Default: `"all"`.

**Result:**
```json
{
  "bodies": ["STAR_SUN", "PLANET_MERCURY", "PLANET_VENUS", "PLANET_EARTH", "..."]
}
```

### 4.2 Body Queries

#### `get_body_info`
Returns properties of a celestial body.

**Params:**
- `name` (string, required) — Body name, e.g. `"PLANET_EARTH"`

**Result:**
```json
{
  "name": "PLANET_EARTH",
  "gui_name": "Earth",
  "flags": 1048,
  "mean_radius": 6.371e6,
  "gravitational_parameter": 3.986e14,
  "parent": "STAR_SUN",
  "satellites": ["MOON_MOON", "SPACECRAFT_ISS"]
}
```

#### `get_body_position`
Returns position vector of a body relative to its parent.

**Params:**
- `name` (string, required)
- `time` (float, optional) — TT J2000 seconds. Default: current simulation time.

**Result:**
```json
{
  "position": [1.496e11, 0.0, 0.0],
  "time": 7.889e8
}
```

#### `get_body_orbit`
Returns orbital elements.

**Params:**
- `name` (string, required)
- `time` (float, optional)

**Result:**
```json
{
  "semi_major_axis": 1.496e11,
  "eccentricity": 0.0167,
  "inclination": 0.0,
  "longitude_ascending_node": -0.196,
  "argument_periapsis": 1.796,
  "period": 3.156e7,
  "orbit_class": "IVOrbit",
  "parent_name": "STAR_SUN",
  "time": 7.889e8
}
```

`orbit_class` is the orbit model's script class name — `"IVOrbit"` for a fixed Keplerian orbit with precession only, `"IVRealPlanetOrbit"` for the linear-element JPL model with secular a/e/i rates and mean-anomaly corrections (enabled per-project via `IVTableOrbitBuilder.use_real_planet_orbits`). Clients can use it to decide whether long-baseline element evolution applies. Falls back to `"IVOrbit"` if the orbit has no script global name. `parent_name` is the body the orbit is about.

#### `get_body_distance`
Returns distance between two bodies.

**Params:**
- `body_a` (string, required)
- `body_b` (string, required)
- `time` (float, optional)

**Result:**
```json
{
  "distance": 3.844e8,
  "time": 7.889e8
}
```

#### `get_body_state_vectors`
Returns position and velocity vectors of a body relative to its parent.

**Params:**
- `name` (string, required)
- `time` (float, optional) — TT J2000 seconds. Default: current simulation time.

**Result:**
```json
{
  "position": [1.496e11, 0.0, 0.0],
  "velocity": [0.0, 2.978e4, 0.0],
  "time": 7.889e8
}
```

Note: Velocity computation is experimental (`@experimental` in IVOrbit).

### 4.3 Controls

#### `select_body`
Select a body by name. Moves camera if camera lock is on.

**Params:**
- `name` (string, required)

**Result:** `{"ok": true}`

#### `select_navigate`
Navigate the selection hierarchy.

**Params:**
- `direction` (string, required) — One of: `"up"`, `"down"`, `"next"`, `"last"`, `"next_planet"`, `"last_planet"`, `"next_moon"`, `"last_moon"`, `"next_spacecraft"`, `"last_spacecraft"`, `"next_star"`, `"last_star"`, `"next_major_moon"`, `"last_major_moon"`, `"history_back"`, `"history_forward"`

**Result:** `{"ok": true, "name": "PLANET_MARS", "gui_name": "Mars"}` — the new selection. Error code 5 if there is nothing in that direction from the current selection.

#### `set_pause`
Pause or resume the simulation.

**Params:**
- `paused` (bool, required)

**Result:** `{"ok": true}`

#### `set_speed`
Change simulation speed.

**Params (one of):**
- `index` (int) — Direct speed index
- `delta` (int) — Increment (+1) or decrement (-1) speed
- `real_time` (bool) — Set to 1x speed if true

**Result:** `{"ok": true, "speed_index": 2, "speed_name": "100x"}`

#### `set_time`
Set simulation time. Requires `IVCoreSettings.allow_time_setting == true`.

**Params (one of):**
- `time` (float) — TT J2000 seconds
- `date` (array) — `[year, month, day]` or `[year, month, day, hour, minute, second]`
- `os_time` (bool) — Sync to operating system time if true

**Result:** `{"ok": true, "time": 7.889e8}`

#### `move_camera`
Low-level camera move. **Prefer the view methods (§4.10) for the common "frame a body" case** — they bind to the same Core entry point the GUI view buttons use and need no hand-built perspective-distance vector. Use `move_camera` only for explicit per-axis control.

**Params:**
- `target` (string, optional) — Body name to move to. Omit to keep the current target.
- `view_position` (array, optional) — `[longitude, latitude, perspective_distance]`. The third element is a *perspective distance*, not meters: scaled by the target's radius when near, blending to an absolute distance when far. This is an `IVCamera` internal — see the `IVCamera` / `IVCameraHandler` class docs (this spec does not restate the formula). Omit to keep the current framing.
- `view_rotations` (array, optional) — `[pitch, yaw, roll]` Euler offsets.
- `tracking` (string, optional) — `"ecliptic"`, `"orbit"` or `"ground"`. Decides what `view_position`'s longitude and latitude are measured in; omit to leave the camera's current tracking mode alone. **`"ground"` is the target's own rotating frame, so latitude is a latitude ON the body** — the only one of the three that poses relative to a body's equator, and therefore to its ring plane. The default `"orbit"` and `"ecliptic"` modes measure latitude in a frame the body's obliquity is tilted from, so posing a ringed planet by latitude there sweeps neither the ring opening angle nor anything else meaningful (measured on Saturn: ecliptic latitude 0° leaves the rings ~26° open and −26° puts them edge-on).
- `instant` (bool, optional) — Skip animation. Default: false.

**Result:** `{"ok": true}`

#### `set_camera_fov`
Zoom the current camera, as the GUI's focal-length control does.

**Params (exactly one of):**
- `fov` (float) — Vertical field of view in degrees, in (0, 180).
- `focal_length` (float) — 35 mm-equivalent focal length in millimetres, > 0.

**Result:** `{"fov": 36.9, "focal_length": 35.0}` — both, whichever was given.

### 4.4 GUI and HUD Visibility

#### `show_hide_gui`
Show or hide all GUI panels. Emits `IVGlobal.show_hide_gui_requested` which is handled by `IVShowHideUI`.

**Params:**
- `visible` (bool, required) — true to show, false to hide

**Result:** `{"ok": true, "visible": true}`

#### `set_huds`
Hides or shows every 3D HUD at once, absolutely rather than by toggling: orbit lines, names and symbols, and the small-body groups' points and orbits. This is what an evaluation screenshot needs — `screenshot`'s `hide_gui` hides the 2D GUI and nothing else, so orbit lines, labels and the asteroid point cloud still draw over the subject. It is the GUI's hide-HUDs button (`IVBodyHUDsState.set_huds_hidden`): hiding leaves each HUD's visibility setting as it was, so showing again restores what was on screen, and the hidden state isn't saved between sessions.

**Params:**
- `visible` (bool, required) — `false` hides every HUD; `true` shows them as their visibility settings have them.

**Result:** `{"ok": true, "visible": false, "huds_hidden": true, "orbit_visible_flags": 1048, "name_visible_flags": 1048, "symbol_visible_flags": 1048, "small_bodies_huds": true}` — `huds_hidden` lets a caller confirm the frame is clean rather than assume it; the flags are the visibility settings the HUDs show with; `small_bodies_huds` says whether the project has small-body HUDs.

Any other HUD visibility change shows the HUDs again: the setters below, the GUI's HUD checkboxes, or a view whose `affects` includes `huds_visibility`. Such a view is also the way to put the visibility settings themselves back to a known state.

The visibility settings persist across sessions, and a project may restore them at startup (the Planetarium's view cacher does), so a test can't assume the state it starts in. `get_huds` reads them, and the setters below return the previous state so a caller can put it back.

#### `get_huds`
Reads every HUD's visibility setting, by body class and by small-body group, and whether `set_huds` has them all hidden. The body classes are those the GUI's HUD checkboxes set, named as `IVBody.BodyFlags` names them without the `BODYFLAGS_` prefix.

**Params:** none

**Result:**
```json
{
  "huds_hidden": false,
  "body_classes": {
    "PLANET": {"names": true, "symbols": true, "orbits": true},
    "ASTEROID": {"names": false, "symbols": false, "orbits": false}
  },
  "name_visible_flags": 8912,
  "symbol_visible_flags": 8912,
  "orbit_visible_flags": 8896,
  "all_flags": 11984,
  "small_body_groups": {
    "SBG_NEAR_EARTH": {"alias": "NE", "symbols": false, "orbits": false}
  }
}
```
(abbreviated). The flags are `IVBody.BodyFlags` bitmasks, as `set_body_orbit_visible_flags` takes. A small-body group's `symbols` are its points. `small_body_groups` is present only when the project has small-body HUDs.

#### `set_class_huds`
Shows or hides one HUD for one or more body classes or small-body groups, as the GUI's HUD checkboxes do (`IVHUDsCheckBox`).

**Params:**
- `hud` (string, required) — `"names"`, `"symbols"` or `"orbits"`. Small-body groups have no names.
- `body_classes` (string or array) — Body classes as `get_huds` names them, e.g. `"PLANET"`; the `BODYFLAGS_` prefix is optional.
- `groups` (string or array) — Small-body groups by name or alias, e.g. `"SBG_JUPITER_L4_TROJANS"` or `"JT4"`.
- `visible` (bool, required)

Supply exactly one of `body_classes` and `groups`.

**Result:** `{"ok": true, "hud": "names", "visible": false, "previous": {"PLANET": true, "DWARF_PLANET": true}, "huds_hidden": false}` — `previous` holds each class's or group's visibility before the call (groups by name), for putting it back.

An unknown body class returns error code 2, an unknown group error code 3.

#### `set_all_body_orbits_visibility`
Show or hide every body's orbit line.

**Params:**
- `visible` (bool, required)

**Result:** `{"ok": true, "previous_flags": <int>, "orbit_visible_flags": 0, "all_flags": <int>}` — `previous_flags` can be passed to `set_body_orbit_visible_flags` to restore exactly; `all_flags` is `IVBodyHUDsState`'s mask of every body flag a HUD can select.

#### `set_body_orbit_visible_flags`
Set which bodies' orbit lines show, as an `IVBody.BodyFlags` bitmask.

**Params:**
- `flags` (int, required)

**Result:** As `set_all_body_orbits_visibility`.

Small-body group points have their own setter, `set_small_body_points_visibility` (§4.9).

### 4.5 Save/Load (requires IVSave plugin)

These methods are only available when the `ivoyager_save` plugin is present and enabled. They appear in `get_project_info` capabilities only when detected. If called without the plugin, they return error code 5 ("Save plugin not available").

Save and load operations are **asynchronous**. The methods return `{"ok": true}` immediately. Poll `get_state` to detect completion via the `is_saving` / `is_loading` fields.

#### `save_game`
Trigger a save operation. Requires simulator started.

**Params:**
- `type` (string, optional, default `"quicksave"`) — One of `"quicksave"`, `"named"`, or `"autosave"`
- `path` (string, optional) — File path for `"named"` saves. If omitted for `"named"`, requests a dialog (not useful for automated testing)

**Result:** `{"ok": true}`

**Example:**
```json
{"id": 1, "method": "save_game", "params": {}}
{"id": 1, "method": "save_game", "params": {"type": "quicksave"}}
{"id": 1, "method": "save_game", "params": {"type": "named", "path": "C:/saves/test.MyProjectSave"}}
```

#### `load_game`
Trigger a load operation. Requires simulator started.

**Params:**
- `path` (string, optional) — Specific save file to load. If omitted, loads the most recently modified save file (quickload)

**Result:** `{"ok": true}`

During load, the readiness gate closes (on `about_to_free_procedural_nodes`) and re-opens after the next `simulator_started` plus `min_ready_delay_frames` frames of the project's `ready_predicate` returning `true` (see §7.3, §7.4). Sim-gated methods (including `save_game` and `load_game`) return error code 4 during this window. Poll `get_state` (always available) until `started` is `true` and `is_loading` is `false`, then allow a brief settling period before re-issuing sim-gated calls — or simply retry on error code 4.

**Example:**
```json
{"id": 1, "method": "load_game", "params": {}}
{"id": 1, "method": "load_game", "params": {"path": "C:/saves/test.MyProjectSave"}}
```

#### `get_save_status`
Query save/load status and file information. Available before simulator starts.

**Params:** none

**Result:**
```json
{
  "is_saving": false,
  "is_loading": false,
  "directory": "C:/Users/user/AppData/Roaming/Godot/app_userdata/ProjectName/saves",
  "has_saves": true,
  "last_modified_path": "C:/Users/.../saves/Quicksave_2026-01-01_12.00.00.MyProjectSave",
  "file_extension": "MyProjectSave"
}
```

### 4.6 Testing Utilities

#### `screenshot`
Capture viewport to a PNG file. Optionally hides GUI before capture and restores it after.

**Params:**
- `path` (string, required) — Output file path (must be a valid writable path)
- `hide_gui` (bool, optional, default false) — Temporarily hide GUI, force a synchronous render, capture, then restore GUI

**Result:**
```json
{
  "ok": true,
  "path": "C:/tmp/screenshot.png",
  "size": [1920, 1080]
}
```

When `hide_gui` is true, the method hides the GUI via `IVGlobal.show_hide_gui_requested`, calls `RenderingServer.force_draw(true)` to synchronously render a frame without GUI, captures, then restores GUI visibility. Alternatively, call `show_hide_gui` separately before `screenshot` — the per-frame TCP processing naturally inserts a render between requests.

### 4.7 Action Emulation

#### `list_actions`
Returns all registered input actions with their display names. Actions are defined by `IVInputMapManager` and include display toggles, camera controls, selection navigation, time controls, and administrative actions.

**Params:** none

**Result:**
```json
{
  "actions": {
	"toggle_all_huds": "Show/Hide All HUDs",
	"toggle_pause": "Toggle Pause",
	"recenter": "Recenter",
    "..."
  }
}
```

#### `press_action`
Emulates a user hotkey press. Injects a real `InputEventKey` into Godot's input pipeline via `Input.parse_input_event()`, so it flows through `_shortcut_input()` handlers exactly like a physical key press. Both press and release events are injected.

**Params:**
- `action` (string, required) — Action name from `list_actions` (e.g. `"toggle_pause"`)

**Result:** `{"ok": true, "action": "toggle_pause"}`

Note: Camera movement actions (e.g. `camera_up`) are designed for sustained key holds. An instant press+release has negligible effect — use `move_camera` for camera positioning instead.

Note: `toggle_all_huds` is a **toggle**, so what it leaves on screen depends on whether the HUDs were already hidden. Use `set_huds` (§4.4) for a deterministic result.

### 4.8 GUI Inspection

Generic scene tree inspection methods that work on any GUI node without per-widget custom code. Available before simulator starts. Capability: `gui_inspection`.

#### `find_nodes`
Discover nodes by class, script class_name, or name pattern.

**Params (at least one required):**
- `class` (string, optional) — Godot built-in class name (e.g., `"TabContainer"`)
- `script_class` (string, optional) — GDScript `class_name` (e.g., `"MyCustomPanel"`)
- `name_pattern` (string, optional) — Glob match on node name (e.g., `"*Panel*"`)
- `root` (string, optional) — Node path to search from (default: `"/root"`)

**Result (example):**
```json
{
  "nodes": [
    {"path": "/root/Universe/TopUI/.../MyPanel", "class": "MarginContainer", "script_class": "MyCustomPanel", "name": "MyPanel", "visible": true}
  ],
  "count": 1
}
```

Capped at 50 results.

#### `inspect_node`
Return a node's type, key properties, and children to a configurable depth.

**Params:**
- `path` (string, required) — Node path from `find_nodes`
- `depth` (int, optional, default 2) — Levels of children to include

**Result:** Nested dictionary tree. Each node includes `name`, `class`, `visible`. Class-specific properties are included automatically: `text` for Labels, `current_tab`/`tab_names` for TabContainers, `title`/`folded` for FoldableContainers.

#### `read_node_text`
Recursively harvest all visible text content from a subtree in document order. This is the primary method for verifying that a GUI widget displays sensible output.

**Params:**
- `path` (string, required) — Node path to walk
- `max_labels` (int, optional, default 200) — Maximum entries to return

**Result (example):**
```json
{
  "path": "/root/.../MyPanel",
  "entries": [
	{"type": "tab_container", "name": "TabContainer", "current_tab": 0, "tab_names": ["Tab1", "Tab2"]},
	{"type": "section", "title": "Section A", "folded": true},
	{"type": "section", "title": "Section B", "folded": false},
	{"type": "label", "name": "value_label", "text": "85"},
	{"type": "label", "name": "rate_label", "text": "2.5"}
  ],
  "count": 5,
  "truncated": false
}
```

**Behavior:**
- Skips invisible nodes entirely
- For TabContainers, only recurses the active tab
- For FoldableContainers, skips folded sections
- Stops at `max_labels` entries, sets `truncated: true`

**Timing note:** Some projects populate GUI content asynchronously (e.g., via deferred calls or background threads). `read_node_text` reads the current display state — it does not trigger or wait for updates. If labels are empty, the data may not yet have populated. Callers should ensure the relevant GUI is active and data has had time to load (e.g., navigate with `select_body`, wait ~2 seconds, then inspect).

**Recommended AI workflow** for "test X for sensible output":
1. `get_state` — confirm simulator running
2. `select_body` — navigate to entity with data
3. Wait ~2 seconds for data population
4. `find_nodes` with `script_class` — discover the node path
5. `read_node_text` with that path — harvest visible text
6. Analyze entries for non-empty values, reasonable numeric ranges, correct section titles

### 4.9 Mouse Hover Identification

Primitives for verifying the user-visible effect of any system that identifies on-screen elements at the mouse position (today this is `IVFragmentIdentifier`'s shader-encoded ids on bodies, orbit lines and asteroid points). Two suites provide them: `MouseTargetIdSuite` (`warp_mouse`, `project_to_screen`, `get_hover_target`; capability `mouse_target_id`) and `SmallBodiesIdSuite` (`list_small_body_groups`, `project_small_body_to_screen`, `set_small_body_points_visibility`; capability `small_bodies_id`), which is present only in projects that load small-body groups (§8.1).

`MouseTargetIdSuite` intentionally observes [`IVMouseTargetLabel.text`](../ivoyager_core/ui/mouse_target_label.gd) — the label the user actually sees — rather than any specific identifier API. Tests written against these methods remain valid across replacement of the underlying identification mechanism (e.g. a future Compositors-based system replacing `IVFragmentIdentifier`).

Every position these methods take or return is in **window pixels**: the pixels of a `screenshot` image. On a hi-DPI screen the Core plugin's display scale makes them finer than the GUI's logical pixels (2.5 to one at 250% Windows scaling), and the methods convert between the two so a client never has to.

#### `warp_mouse`
Synthesize an `InputEventMouseMotion` at a window pixel position. Updates `IVWorldController.mouse_position` (and any other input subscribers) the same way an OS-generated mouse event would, without moving the visible OS cursor.

**Params:**
- `position` (array, required) — `[x, y]` in window pixel coordinates

**Result:**
```json
{"ok": true, "position": [640.0, 360.0]}
```

#### `project_to_screen`
Project a 3D world position to a window pixel via the active `Camera3D.unproject_position()`. Use to find good test coordinates for hover assertions: project a body for body-pixel hover, or a body at a future time to land on its orbit line. Asteroids have their own method, `project_small_body_to_screen`.

**Params (exactly one of `body` or `world_position` required):**
- `body` (string) — Body name; projects the body's current Node3D `global_position` (already in Godot scene-tree world coordinates).
- `time` (float, optional, only with `body`) — TT J2000 seconds. When supplied, projects the body's position at that time (computed by walking the parent chain, summing each ancestor's per-parent local orbit position, and anchoring at the topmost body's `global_position`). A `time` other than current places the projected pixel on the body's orbit line where the body itself isn't — the hook for orbit-line hover testing.
- `world_position` (array) — `[x, y, z]` in Godot scene-tree world coordinates (the same space as any `Node3D.global_position` in the scene). Note: position values returned by `get_body_position` / `get_body_state_vectors` are in Godot scene-tree units relative to the body's parent (not heliocentric world); anchor them by adding the parent body's `global_position` if you need world-space input here.

**Result:**
```json
{
  "position": [820.5, 412.0],
  "on_screen": true,
  "behind_camera": false,
  "world_position_used": [-329046784.0, 235556144.0, -161255408.0]
}
```

`on_screen` is `true` only when `behind_camera` is `false` AND the projected pixel is inside the viewport rect. `world_position_used` is the Godot scene-tree world coordinate that was projected — useful for diagnosing scale or anchoring mismatches when projections land off-screen unexpectedly.

#### `project_small_body_to_screen`
Project one asteroid of an [`IVSmallBodiesGroup`](../ivoyager_core/tree/small_bodies_group.gd) to a window pixel, for SBG-point hover tests. Its position at the current sim time is computed from the group's stored Keplerian elements.

**Params:**
- `group` (string, required) — SBG name (discover via `list_small_body_groups`).
- `index` (int, required) — Element index within the group, `[0, count)`.

**Result:** As `project_to_screen`, plus `"name"`, the asteroid's entry in `IVSmallBodiesGroup.names`.

**Limitations:**
- Trojan / Lagrange-point groups (`lp_integer != -1`) are rejected with error code 2; their librating positions need a different model.
- Precession of LAN and AP (rates from `IVSmallBodiesGroup.s_g_mag`) is not applied. For main-belt asteroids the per-decade drift is well within `IVFragmentIdentifier`'s ~9-pixel sample radius, so the projected pixel still falls inside the rendered point's identification grid for typical sim time deltas from epoch. The mean anomaly rate, by contrast, is applied through `IVSmallBodiesGroup.get_mean_anomaly_rate()` — the stored `n` is the mean longitude rate, so using it directly would drift by `g` per unit time.

#### `set_small_body_points_visibility`
Show or hide one group's points. Core shows no group's points by default, and a hidden point can't be identified under the mouse, so an SBG-point hover test turns its group on first. Visibility persists across sessions like the other HUDs (§4.4).

**Params:**
- `group` (string, required) — SBG name.
- `visible` (bool, required)

**Result:** `{"ok": true, "previous": false, "visible": true}` — pass `previous` back to restore.

#### `list_small_body_groups`
Enumerate loaded `IVSmallBodiesGroup` instances, for valid `group` values.

**Params:** none

**Result:**
```json
{
  "groups": [
	{"name": "MPC_NEAR_EARTH_OBJECTS", "alias": "NEAs", "count": 1234, "lp_integer": -1},
	{"name": "JT4", "alias": "JT4", "count": 5678, "lp_integer": 4}
  ]
}
```

`lp_integer` is `-1` for normal heliocentric groups; `4` or `5` for Jupiter Trojans (L4/L5). Trojan groups cannot be passed to `project_small_body_to_screen` (see Limitations above).

#### `get_hover_target`
Return the current state of `IVMouseTargetLabel` — the user-visible identification of whatever shader element is under the mouse.

**Params:** none

**Result:**
```json
{
  "text": "Mars (orbit)",
  "visible": true,
  "mouse_position": [830.0, 412.0]
}
```

**Timing note:** `IVFragmentIdentifier` samples a SubViewport and runs an 8-frame calibration/value cycle before reporting an id. Allow ~250–400 ms (≥ ~16 frames at 60 Hz, doubling the cycle length for safety) between `warp_mouse` and the first reliable `get_hover_target` reading. Replacement implementations may have different timing — clients should poll `get_hover_target` until the text stabilizes rather than relying on a fixed delay.

**Recommended hover-test workflow:**
1. `move_camera` to a vantage point that puts the test target on-screen. Make the target's HUD visible: its orbit line for an orbit-line test (`set_all_body_orbits_visibility`), its group's points for an asteroid test (`set_small_body_points_visibility`).
2. Wait ~1 s for camera and HUDs to settle.
3. `project_to_screen` with `body` (or `project_small_body_to_screen`) to get the target's projected pixel.
4. `warp_mouse` to that pixel (or a small offset for orbit-line tests).
5. Sleep / poll briefly; call `get_hover_target` and assert on `text`.
6. Restore any HUD visibility you changed.

### 4.10 Views

Named built-in views are the GUI-parity way to frame the camera and (optionally) reset HUD/time state. Each maps to a row in `tables/views.tsv` and is the exact target of a default `IVViewButton` (`pressed → IVViewManager.set_table_view`). See §10 (Core surface classes). These are the standard "frame a body" controls — prefer them over `move_camera`.

#### `list_views`
Enumerate built-in (table-defined) views with decoded fields. The user's own saved views are listed by `list_cached_views`.

**Params:** none.

**Result:**
```json
{
  "views": {
    "VIEW_ZOOM": {
      "scope": "table",
      "target_name": "",
      "tracking": "none",
      "up_lock": "locked",
      "view_position": [null, 0.314, 0.003],
      "affects": ["camera_longitude", "camera_orientation"]
    }
  }
}
```

Field meanings:
- `target_name` — camera target body, or `""` to keep the current selection.
- `tracking` — one of `ground`, `orbit`, `ecliptic`, `galactic`, `supergalactic`, `none`.
- `up_lock` — one of `locked`, `unlocked`, `unset`.
- `view_position` — `[longitude, latitude, perspective_distance]`; each element is `null` where the view keeps the current value (e.g. `VIEW_ZOOM` leaves longitude unset). The third element is a perspective distance, not meters (see the `IVCamera` class docs).
- `affects` — the state categories the view overwrites when applied: any of `camera_selection`, `camera_longitude`, `camera_orientation`, `huds_visibility`, `huds_color`, `time_state`, `sync_os_time`. Lets a client see a view's blast radius (e.g. `VIEW_ZOOM` only moves the camera; `VIEW_HOME` also resets HUDs).

#### `apply_view`
Apply a built-in view by name — the standard way to frame the camera. Equivalent to clicking the matching GUI view button.

**Params:**
- `name` (string, required) — A view name from `list_views` (e.g. `"VIEW_ZOOM"`, `"VIEW_HOME"`).
- `instant` (bool, optional, default false) — Skip the camera animation. Pass `true` before a `screenshot`.

**Result:** `{"ok": true, "name": "VIEW_ZOOM"}`

Unknown `name` returns error code 2 (call `list_views` for valid names).

#### `list_cached_views`
Enumerate the views the user saved by hand, which a project keeps between sessions. Use one to reproduce a staging the user set up rather than hunting for it with `move_camera`.

**Params:** none.

**Result:** As `list_views`, keyed `"<name>.<collection>"`, with `"scope": "cached"` and the view's `name` and `collection` split out:
```json
{
  "views": {
    "Saturn rings.CP": {
      "scope": "cached",
      "name": "Saturn rings",
      "collection": "CP",
      "target_name": "PLANET_SATURN",
      "tracking": "ground",
      "up_lock": "locked",
      "view_position": [0.5, 0.35, 0.01],
      "affects": ["camera_selection", "camera_longitude", "camera_orientation", "huds_visibility"]
    }
  }
}
```

#### `apply_cached_view`
Apply one of the user's saved views, as the GUI's saved-view buttons do.

**Params:**
- `name` (string, required) — The view's `name` from `list_cached_views`.
- `collection` (string, optional, default `""`) — Its `collection`.
- `instant` (bool, optional, default false) — Skip the camera animation.

**Result:** `{"ok": true, "name": "Saturn rings", "collection": "CP"}`

An unknown view returns error code 2.

### 4.11 User Settings

User settings are `IVSettingsManager`'s: those the Options popup (`IVOptionsPopup`) shows, and any a project keeps out of it. They exist before the simulator starts, so these methods work from a splash screen too.

#### `get_options`
Reads every setting, or one.

**Params:**
- `setting` (string, optional) — A setting's key. Omit for all.

**Result:**
```json
{
  "settings": {
    "atmosphere_quality": {"value": 1, "default": 1, "type": "int", "restart_pending": false,
        "enumeration": ["ATMOSPHERE_NORMAL", "ATMOSPHERE_REDUCED", "ATMOSPHERE_MIN", "ATMOSPHERE_OFF"]},
    "glow": {"value": true, "default": true, "type": "bool", "restart_pending": false}
  },
  "restart_pending": false,
  "cache_current": true
}
```
(abbreviated). With `setting`, the result is that one setting's entry, plus `"setting"`.

- `type` is the Godot type of the setting's default, which a new value must match. A `Color` reads as `"#rrggbb"`, or `"#rrggbbaa"` when translucent.
- `enumeration` names the values of a setting the Options popup offers as a dropdown, in order, so `value` indexes it. The names are untranslated text keys. Absent for other settings, and where the project has no Options popup.
- `default` is this machine's: a project that sets `IVSettingsManager.graphics_target` fits its graphics defaults to the hardware.
- `restart_pending` is true for a setting that takes effect only at startup and now differs from what the running session uses; at the top level, for any setting.
- `cache_current` is false while a change has not been written to the settings file.

#### `set_option`
Changes a setting, as the Options popup does (`IVSettingsManager.change_setting`).

**Params:**
- `setting` (string, required)
- `value` (required) — Of the setting's `type`. An integer setting with an `enumeration` also takes one of its names, and a `Color` takes an HTML color string.
- `persist` (bool, optional, default false) — Also write the settings file, as the popup's Confirm button does.

**Result:** `{"ok": true, "setting": "atmosphere_quality", "value": 2, "previous": 1, "restart_pending": true, "cache_current": false}` — `previous` is for putting it back.

An unpersisted change lasts until quit, so a test run leaves the user's next session alone — unless something persists a setting first. The settings file is written whole, so `persist`, the popup's Confirm, and GUI controls that change a setting directly (the HUDs panel's size spinboxes) write every pending change along with their own. A setting that comes back `restart_pending` takes effect only at the next start, so it needs `persist`.

An unknown setting, or a value that doesn't fit its type or enumeration, returns error code 2.

## 5. Core API Dependencies

The AssistantServer reads from and writes to these core objects:

| Object | Access Pattern | Used For |
|--------|---------------|----------|
| `IVStateManager` | Autoload singleton | State flags, lifecycle signals, `set_user_paused()` |
| `IVGlobal` | Autoload singleton | `times[]`, `date[]`, `clock[]`, `program{}` |
| `IVBody.bodies` | Static dictionary | Body lookup by name |
| `IVBody` instance | Via bodies dict | Position, velocity, orbit, flags, properties |
| `IVOrbit` | Via `body.get_orbit()` | Orbital elements |
| `SelectionManager` | Via `IVGlobal.program[&"TopUI"].selection_manager` | Selection state and control |
| `SpeedManager` | Via `IVGlobal.program[&"SpeedManager"]` | Speed index, `change_speed()` |
| `Timekeeper` | Via `IVGlobal.program[&"Timekeeper"]` | Time queries and `set_time()` |
| `CameraHandler` | Via `IVGlobal.program[&"CameraHandler"]` | Camera state and `move_to()` |
| `IVViewManager` | Via `IVGlobal.program[&"ViewManager"]` | Table and cached views: `set_table_view()`, `set_view()` |
| `IVBodyHUDsState` | Via `IVGlobal.program[&"BodyHUDsState"]` | Body HUD visibility (orbits, names, symbols) |
| `IVSBGHUDsState` | Via `IVGlobal.program[&"SBGHUDsState"]` (optional) | Small-body group points and orbits visibility |
| `IVSettingsManager` | Autoload singleton | User settings: `get_setting_keys()`, `get_setting()`, `get_default()`, `change_setting()`, restart and cache state |
| `IVOptionsPopup` | Found anywhere in the tree (optional) | `option_enumerations`, to name a dropdown setting's values |
| `IVInputMapManager` | Static `defaults` / `action_texts` | Action listing for `list_actions` |
| `IVMouseTargetLabel` | Found under `IVGlobal.program[&"TopUI"]` | Read `text` / `visible` for hover-target identification (independent of the underlying identifier mechanism) |
| `Camera3D` / `IVCamera` | Via `Viewport.get_camera_3d()` | `unproject_position()` for world-to-screen projection; `set_field_of_view()` / `set_focal_length()` |
| `IVSmallBodiesGroup` | Static `small_bodies_groups` registry + `get_orbit_elements()` / `get_mean_anomaly_rate()` / `names` | Asteroid enumeration and per-asteroid Keplerian elements for `project_small_body_to_screen` |
| `IVOrbit` | Static `get_true_anomaly_from_mean_anomaly_elliptic()` and `get_position_from_elements_at_true_anomaly()` | Asteroid position from elements at current sim time |
| `IVSave` | Autoload singleton (optional) | Save/load operations, save status queries (duck-typed) |

## 6. Threading and Safety

- All TCP I/O and command processing runs on the main thread in `_process()`
- This is safe for scene tree access but limits throughput to frame rate (~60 Hz)
- For a testing/accessibility interface, sub-16ms latency is adequate
- The server processes all pending complete messages each frame (not just one)

## 7. Configuration

`ivoyager_assistant.cfg` (abbreviated):

```ini
[assistant_autoload]
IVAssistantServer="../assistant_server.gd"

[assistant_test_suites]
StateQuerySuite="res://addons/ivoyager_assistant/test_suites/state_query_suite.gd"
; ...one line per default suite (§7.2)

[assistant]
port=29071
enabled=true
debug_only=true
assistant_name=""
context_file=""
min_ready_delay_frames=10
```

### 7.1 Autoload Registration

The `[assistant_autoload]` section declares autoloads managed by the EditorPlugin. When the plugin is enabled in Godot's Plugin manager, `IVAssistantServer` is registered as an autoload. Projects can negate the autoload by setting `IVAssistantServer=""` in `ivoyager_override.cfg`.

### 7.2 Test Suites

The `[assistant_test_suites]` section registers `IVAssistantTestSuite` subclasses that provide API methods to the server. Each entry maps a suite name to a GDScript file path. The server loads these on `core_initialized`, calls `_init_test_suite()` on each, and builds a method dispatch table from their `get_method_names()` return values.

**Default suites:**

| Suite | Methods |
|---|---|
| `StateQuerySuite` | `get_time`, `get_selection`, `get_camera`, `list_bodies`, `get_body_info`, `get_body_position`, `get_body_orbit`, `get_body_distance`, `get_body_state_vectors` |
| `ControlSuite` | `select_body`, `select_navigate`, `set_pause`, `set_speed`, `set_time`, `move_camera`, `set_camera_fov`, `show_hide_gui`, `list_actions`, `press_action`, `set_all_body_orbits_visibility`, `set_body_orbit_visible_flags`, `set_huds`, `get_huds`, `set_class_huds` |
| `ViewSuite` | `list_views`, `apply_view`, `list_cached_views`, `apply_cached_view` |
| `SettingsSuite` | `get_options`, `set_option` |
| `CoreTestSuite` | `screenshot`, `save_game`, `load_game`, `get_save_status` |
| `GuiInspectionSuite` | `find_nodes`, `inspect_node`, `read_node_text` |
| `MouseTargetIdSuite` | `warp_mouse`, `project_to_screen`, `get_hover_target` |
| `SmallBodiesIdSuite` | `project_small_body_to_screen`, `list_small_body_groups`, `set_small_body_points_visibility` |

**Override examples** (in `ivoyager_override.cfg` or `ivoyager_override2.cfg`):

```ini
[assistant_test_suites]
; Remove a suite entirely:
CoreTestSuite=null

; Replace a suite with a custom implementation:
StateQuerySuite="res://custom/my_query_suite.gd"

; Add a new suite alongside the defaults:
MyProjectTests="res://tests/my_project_tests.gd"
```

Setting a suite to `null` or `""` removes it. Adding a new key registers a new suite. If two suites register the same method name, the last one loaded wins (with a warning).

**Creating a custom test suite:**

Extend `IVAssistantTestSuite` and override:
- `get_method_names()` — Return the method names your suite handles
- `get_method_requirements()` — Map<method_name, Array[String]> of requirement tokens (see §7.5). Methods whose tokens evaluate false at load time (or at `simulator_started`, for `widget.*` and `runtime.*` tokens) are dropped from the dispatch table and reported in `gated_out`.
- `get_method_summaries()` — Optional Map<method_name, String> of one-line summaries surfaced in the `methods` field of `get_project_info`.
- `is_applicable()` — Return `false` to opt out of the entire suite. Use for all-or-nothing dependencies that don't fit the per-method token vocabulary (e.g. an asteroid-only suite checking `&"asteroids" in IVCoreSettings.body_tables`).
- `get_capabilities()` — Return additional capability strings (feature-group identifiers, e.g. `"mouse_target_id"`) that aren't method names. Most suites can leave this empty: the server already advertises every active method name in `capabilities`.
- `dispatch(method, params)` — Handle method calls, return result or `_error` dict
- `requires_sim_started()` — Return `false` if some methods work before sim starts (default: `true`)
- `_on_simulator_started()` / `_on_about_to_free()` — Cache/clear program references

The suite receives the server node via `_init_test_suite(server)`; use `_server.get_viewport()` for viewport access and `_server.is_ready()` for the readiness gate (§7.4). `IVAssistantTestSuite` has static helpers for parsing params and reporting results: `parse_body()`, `parse_vector3()`, `get_global_position()` and `to_window_pixels()`.

### 7.3 Runtime Settings

The `[assistant]` section controls runtime behavior:

- `port` — TCP listen port (default: 29071)
- `enabled` — Master enable/disable (default: true). When false, the autoload node exists but does not start the TCP server.
- `debug_only` — If true, server only starts when `OS.is_debug_build()` is true (default: true)
- `assistant_name` — Display name for the assistant persona (default: empty, uses project name from ProjectSettings)
- `context_file` — Path to a text file (`res://` relative) with project-specific context for AI clients (default: empty)
- `min_ready_delay_frames` — Number of consecutive frames the project's `ready_predicate` must return `true` (after `simulator_started`) before sim-gated methods become available (default: 10). Allows projects with deferred main-thread work after `simulator_started` (e.g. cross-thread initialization arriving via `call_deferred`) to settle before save/load and similar operations are permitted. See §7.4.

Base values in `ivoyager_assistant.cfg` can be overridden per-project via `ivoyager_override.cfg` or `ivoyager_override2.cfg`.

Two command-line user arguments (after Godot's `--` separator) override these per process, for running several instances of one project at once:

- `--assistant-port=<port>` — listen on this port instead of the configured one.
- `--assistant-instance=<id>` — an arbitrary token echoed as `instance_id` in `get_project_info`.

```
<godot_console_exe> --headless --path <project> -- --assistant-port=29072 --assistant-instance=run-a
```

Each instance needs its own port. A second instance on a port already taken logs `failed to listen on port` and stays unreachable, while a client connecting to that port reaches the first instance; `instance_id` is how a client can tell.

`GodotLauncher` in `tools/assistant_test.py` passes both: its `port` defaults to 29071, and `port=0` picks a free one (read back as `launcher.port`). After connecting, `check_instance()` verifies the echo. Its launched Godot also dies with the Python process that started it, even one killed outright (Windows), so an aborted script leaves no instance holding a port. And it is held to one logical processor of each core (Windows), since Windows can otherwise put the busy threads of instances run at once two to a core, each running slower than it would alone; `one_per_core=False` leaves it where the OS puts it.

### 7.4 Project-supplied readiness predicate

Projects with cross-thread or deferred initialization that continues past `simulator_started` can supply a readiness predicate that the server polls each frame:

```gdscript
IVAssistantServer.ready_predicate = func() -> bool:
	return MyProject.is_initialization_complete
```

The readiness gate stays closed until the predicate has returned `true` for `min_ready_delay_frames` consecutive frames (counted from the first frame the predicate returns `true`, not from `simulator_started`). If the predicate flips back to `false` while counting, the countdown resets. Once the gate has opened, it stays open until reset by `IVStateManager.about_to_free_procedural_nodes` (e.g. during a load).

The default predicate is trivially `true`, so projects that don't set `ready_predicate` get only the `min_ready_delay_frames` buffer after `simulator_started`.

Test suites that opt out of the suite-wide gate (`requires_sim_started()` returns `false`) can still consult the gate per-method via `IVAssistantServer.is_ready()`. The bundled `CoreTestSuite` uses this for `save_game` and `load_game` so save/load races against deferred initialization are blocked even when the suite handles other methods (e.g. `get_save_status`) pre-simulator.

### 7.5 Requirement-Token Vocabulary

`IVAssistantTestSuite.get_method_requirements()` returns a Map<method_name, Array[String]>. Each string is a requirement token from the closed vocabulary defined in `IVAssistantServer.KNOWN_TOKENS`. Unknown tokens `push_error` at suite load and are dropped (the method is then registered as unconditionally available, matching the suite-author's intent of "no recognized restriction").

A method is **active** (callable, listed in `capabilities`, listed under `methods` in `get_project_info`) iff every token in its requirement list resolves true. Methods with at least one unmet token are dropped from the dispatch table — calling one returns `ERR_UNKNOWN_METHOD`, identical to a never-implemented method — and are listed under `gated_out` in `get_project_info` with the unmet token names.

The vocabulary:

| Token | Resolves to |
|---|---|
| `core.allow_time_setting` | `IVCoreSettings.allow_time_setting` |
| `core.allow_time_reversal` | `IVCoreSettings.allow_time_reversal` |
| `program.TopUI` | `IVGlobal.program.has(&"TopUI")` |
| `program.SpeedManager` | `IVGlobal.program.has(&"SpeedManager")` |
| `program.Timekeeper` | `IVGlobal.program.has(&"Timekeeper")` |
| `program.CameraHandler` | `IVGlobal.program.has(&"CameraHandler")` |
| `program.ViewManager` | `IVGlobal.program.has(&"ViewManager")` |
| `program.BodyHUDsState` | `IVGlobal.program.has(&"BodyHUDsState")` |
| `autoload.IVSave` | autoload at `/root/IVSave` is present |
| `body_table.stars` | `&"stars" in IVCoreSettings.body_tables` |
| `body_table.planets` | `&"planets" in IVCoreSettings.body_tables` |
| `body_table.moons` | `&"moons" in IVCoreSettings.body_tables` |
| `body_table.asteroids` | `&"asteroids" in IVCoreSettings.body_tables` |
| `body_table.spacecrafts` | `&"spacecrafts" in IVCoreSettings.body_tables` |
| `widget.MouseTargetLabel` | `IVMouseTargetLabel` reachable under `program.TopUI` after `simulator_started` |
| `runtime.IVSmallBodiesGroup` | `IVSmallBodiesGroup.small_bodies_groups` non-empty after `simulator_started` |

`core.*`, `program.*`, `autoload.*`, and `body_table.*` tokens resolve at `core_initialized` time (when suites load). `widget.*` and `runtime.*` tokens are evaluated against post-init state on `simulator_started`; before sim start they resolve false (the gated method is not active). After sim start the gating refreshes once. Clients querying `get_project_info` before vs after `start_game` see different `capabilities` / `gated_out` lists for those tokens — the post-start query is authoritative.

Suites that need a coarser opt-out than the per-method vocabulary supports can override `is_applicable() -> bool` to short-circuit registration entirely. The check fires once at `core_initialized`, so `is_applicable()` is the right tool for config-driven all-or-nothing decisions (e.g. a flag in `IVCoreSettings` that a project sets in its preinitializer). For runtime conditions known only after the system tree is built, use a per-method `runtime.*` requirement instead.

To extend the vocabulary, add an entry to `KNOWN_TOKENS` and a corresponding case in `_evaluate_token()` in `assistant_server.gd`. Tokens are stringly-typed and validated at suite load, so typos in suite code surface immediately as a `push_error`.

## 8. Cross-Project Compatibility

The plugin is designed as a git submodule usable across any I, Voyager project. Enable the plugin in Project Settings → Plugins — no project-level config changes are needed.

### 8.1 Feature Availability

Not all projects support all features. `get_project_info` returns three related fields that describe the current configuration:

- `capabilities` — Flat string array of every active method name plus suite-supplied feature flags (`"gui_inspection"`, `"mouse_target_id"`, `"small_bodies_id"`). This is the canonical source for AI clients deciding whether to call a method.
- `methods` — Map<method_name, {summary?: String}> covering every active method. The shape is reserved for future per-method metadata; today only the optional `summary` is populated.
- `gated_out` — Array of `{"method": String, "unmet": Array[String]}` entries, one per registered-but-currently-unavailable method, naming the requirement tokens that resolved false. Lets clients distinguish "this build doesn't support X" from "X doesn't exist."

Gating is driven by the per-method requirement-token vocabulary (see §7.5). Concretely:

- **Program objects**: Methods declaring a `program.*` token (`TopUI`, `CameraHandler`, `SpeedManager`, `Timekeeper`, `ViewManager`, `BodyHUDsState`) only activate when that program object is registered.
- **Settings**: `set_time` declares `core.allow_time_setting`, so it activates only when `IVCoreSettings.allow_time_setting == true`.
- **Project type**: `start_game` is hard-coded into `capabilities` only for projects with `IVCoreSettings.wait_for_start == true`.
- **Plugins**: `save_game`, `load_game`, and `get_save_status` declare `autoload.IVSave`, so they activate only when the `ivoyager_save` plugin is present.
- **Small-bodies groups**: `SmallBodiesIdSuite`'s methods declare `runtime.IVSmallBodiesGroup`. They activate only after `simulator_started` if `IVSmallBodiesGroup.small_bodies_groups` has at least one entry — i.e. the project's `small_bodies_groups` table has any non-`skip` rows and `IVTableSystemBuilder.add_small_bodies_groups` is true. (This is **not** the same as `body_table.asteroids`: that flag controls whether the few "explored" asteroids are loaded as `IVBody` instances; the SBG point clouds the suite actually targets are populated from the separate `small_bodies_groups` table.)
- **Widgets**: `get_hover_target` declares `widget.MouseTargetLabel` and activates only after `simulator_started` if an `IVMouseTargetLabel` is reachable under `program.TopUI`.

Calling a gated-out method returns `ERR_UNKNOWN_METHOD`. The protocol intentionally collapses "method not implemented" and "method gated out by configuration" into the same error: a missing capability looks identical to a never-implemented one, which is what clients should treat it as. The `gated_out` list is informational — clients that want to explain *why* a method is unavailable can read it.

The manifest version is reported as `assistant_protocol_version` (currently `3`, which added `process_id`, `port` and `instance_id`); fields are added additively across versions.

### 8.2 Splash Screen Handling

Projects with `wait_for_start = true` display a splash screen before starting the simulation. The TCP server starts on `core_initialized` (before the splash screen), allowing AI clients to:

1. Connect and call `get_project_info` to discover the project
2. Poll `get_state` to check `started` status
3. Call `start_game` to programmatically start the simulation (bypassing the splash screen)

### 8.3 Project Identity

Projects can customize the assistant's identity via config:
- `assistant_name` — Gives the assistant a project-specific name
- `context_file` — Points to a text file with background information, personality guidelines, or project-specific instructions for AI clients

## 9. Generic Test Sequence

This section describes how to launch, connect, and run the generic tests that the Assistant plugin provides. These tests verify basic simulation functionality and work across all I, Voyager projects with the plugin enabled.

### 9.1 Launch

Run the Godot project from the command line in debug mode, with `--path` pointing to the project directory:

```
<godot_console_exe> --path .
```

Portable Godot executables are in the parent directory of the project (`../`). Use the newest `Godot_v*_console.exe` of the major version (4.6, 4.7, ...) the project's `config/features` names; `python tools/godot_executable.py <project>` prints it. Don't choose by version number or file date alone: a build of another major rewrites `project.godot`, import files and scenes for its own version when it opens the project. The console variant outputs to stdout/stderr, which is useful for observing errors during testing. To run alongside another instance of the project, give each its own port (§7.3).

### 9.2 Connect

Connect via TCP to `127.0.0.1:29071`, or the port passed with `--assistant-port`. The server starts listening on `core_initialized`, which may take a few seconds after launch. Retry the connection with a short delay (e.g., 2 seconds) if refused.

### 9.3 Test Steps

Execute these steps in order:

1. **Discover capabilities:** Call `get_project_info`. Check `wait_for_start`, `started`, and `capabilities` in the response.
2. **Start the simulation:** If `wait_for_start` is `true` and `started` is `false`, call `start_game`. Then poll `get_state` until `started` is `true`.
3. **Verify state:** Call `get_state`, `get_time`, `get_selection`, `get_camera` and confirm reasonable values.
4. **Exercise controls:** Call `select_body` (e.g., `{"name": "PLANET_MARS"}`), `move_camera` (e.g., `{"target": "PLANET_EARTH", "instant": true}`), `set_pause`, `set_speed`.
   - **Mouse hover** (if `mouse_target_id` is in capabilities, and the game renders): identify a body, an orbit line and an asteroid point under the mouse, as in §4.9.
5. **Save/load cycle** (if `save_game` and `load_game` are in capabilities): Call `save_game`, then poll `get_state` until `is_saving` is `false`. Call `load_game`, then poll `get_state` until `is_loading` is `false` and `started` is `true`.
6. **Quit:** Call `quit` with `{"force": true}` to shut down without a confirmation dialog.

### 9.3.1 Automated Test Runner

The file `tools/assistant_test.py` implements the full test sequence above as an automated Python script. It requires Python 3 (stdlib only, no dependencies). Usage:

```
python tools/assistant_test.py                  # game already running on port 29071
python tools/assistant_test.py --port 29072     # game already running on another port
python tools/assistant_test.py --launch         # start Godot automatically, then test
python tools/assistant_test.py --launch --headless  # no rendering; skips the hover test
python tools/assistant_test.py --skip-save      # skip the save/load cycle
python tools/assistant_test.py --skip-hover     # skip the mouse-hover test
```

`--project` names the project directory (default: the current directory) and `--host` the server host. `--launch` runs the build `tools/godot_executable.py` chooses for the project (§9.1), or the one `--godot` names, and starts it on a free port (unless `--port` is given), so several runs can go at once. The launched Godot does not outlive the script, even if the script is killed, and is held to one logical processor of each core (Windows). It also reports any object or resource leaks Godot prints at quit, and fails the run if there are any.

The script is capability-aware: it checks the `capabilities` array from `get_project_info` and skips tests for features the project does not support. Exit code is 0 on success, 1 on failure.

`tools/orbit_accuracy_test.py` uses the same client and launcher to check body positions against JPL Horizons reference vectors; its module docstring is its specification.

### 9.4 Key Notes

- **Async save/load:** `save_game` and `load_game` return `{"ok": true}` immediately. Poll `get_state` to check `is_saving`/`is_loading` for completion. During load, most methods return error code 4 — only `get_state` and `get_save_status` remain available.
- **Error code 4 (simulator not ready):** If received, poll `get_state` and retry. This occurs before `start_game` completes, during load operations, and during the readiness-gate delay after `simulator_started` (default 10 frames; longer if the project supplies a `ready_predicate`). Note that `started == true` is necessary but not sufficient — sim-gated methods may briefly continue to return error 4 after `started` flips true while the readiness gate is still closing its delay window. Simply retry on error 4.
- **Per-frame processing:** Commands are processed once per frame (~60 Hz). Between a request and its response, at least one game frame passes.
- **Capabilities are authoritative:** Only call methods listed in the `capabilities` array from `get_project_info`. Missing capabilities indicate the project lacks the required program objects or plugins.

## 10. Core surface classes (layering principle)

Assistant methods bind to the **same Core entry points the GUI widgets bind to, at the same abstraction level.** When a control already exists in the GUI, the Assistant method that exposes it should call the same Core method the widget's signal handler calls — not a lower-level primitive. This keeps an automated action and a user's button click semantically identical and on the same code path, which serves both goals in §1: faithful testing, and accessibility as genuine GUI substitution.

Reaching below that surface is a deliberate, marked exception. There are two today:

- `move_camera` bypasses the view layer and hand-supplies a perspective-distance `view_position` (documented as low-level in §4.3). Camera framing should normally go through the view methods (§4.10), which call `IVViewManager.set_table_view` — exactly what the GUI view buttons do.
- The HUD visibility setters (`set_all_body_orbits_visibility`, `set_body_orbit_visible_flags`, `set_small_body_points_visibility`) set visibility in bulk, by raw flags or through a lower setter, which no GUI widget does. `set_class_huds` is the widget-level path.

| Control group | GUI widget script | Core class.method |
|---|---|---|
| Apply named view | `ui_widgets/view_button.gd` (`IVViewButton`) | `IVViewManager.set_table_view` (default views); `IVViewManager.set_view` (user/cached) |
| Select / navigate body | `ui_widgets/nav_button.gd`, `selection_buttons.gd` | `IVSelectionManager.select_by_name` / navigation methods |
| Simulation speed | `ui_widgets/speed_buttons.gd` | `IVSpeedManager.change_speed` |
| Pause | `ui_widgets/pause_button.gd` | `IVStateManager.set_user_paused` |
| Time | `ui_widgets/time_setter.gd` | `IVTimekeeper.set_time` / related |
| Camera zoom | `ui_widgets/focal_length_control.gd` | `IVCamera.set_focal_length` (and `set_field_of_view`) |
| Camera (low-level) | — (no GUI widget hand-supplies a `view_position`) | `IVCameraHandler.move_to` / `move_to_by_name` — perspective-distance system; **below the view layer, a marked exception** |
| Hide all HUDs | `ui_widgets/hide_huds_button.gd` (`IVHideHUDsButton`) | `IVBodyHUDsState.set_huds_hidden` |
| HUD visibility by class | `ui_widgets/huds_checkbox.gd` (`IVHUDsCheckBox`) | `IVBodyHUDsState` `set_name_visibility` / `set_symbol_visibility` / `set_orbit_visibility`; `IVSBGHUDsState` `set_visible_symbols_groups` / `set_visible_orbits_groups` |
| HUD visibility, bulk or raw | — (the checkboxes set one class or group) | `IVBodyHUDsState` `set_all_orbits_visibility` / `set_orbit_visible_flags`; `IVSBGHUDsState.change_symbols_visibility` — **beside the widget layer, a marked exception** |
| User settings | `ui/options_popup.gd` (`IVOptionsPopup`) | `IVSettingsManager.change_setting`; `cache_now` on Confirm |

New write-side Assistant methods should add a row here and bind at the widget level.

> **Planned (not yet implemented):** automation — any class, widgets included, declares what a client may read and call through `AUTOMATION_*` members, with its doc comments as descriptions and, for a widget, Godot's accessibility properties; the Assistant discovers and dispatches these without knowing Core. The principle above then becomes guidance for the declaring class, and the token vocabulary of §7.5 retires. See CODING_PLAN.md ("Automation"). It is intentionally absent from the method catalog above until implemented.
