# I, Voyager Assistant — Specification

## 1. Purpose

The Assistant plugin provides a programmatic interface to the I, Voyager simulation with two goals:

1. **AI-assisted testing** — Enable AI tools (Claude Code) to query simulation state and exercise controls, verifying correctness of orbital mechanics, scene tree construction, time management, and GUI behavior.
2. **Accessibility** — Provide a command-based interface that can be driven by voice control, screen readers, or other assistive technologies for solar system navigation.

The plugin knows Godot, not the project. A project's classes declare what a client may read and call (§11), and the Assistant discovers and dispatches those declarations; so a change in Core or in a project needs no change here.

## 2. Architecture

### 2.1 Integration with a project

- **EditorPlugin** — Registers `IVAssistantServer` as an autoload via `add_autoload_singleton()` when the plugin is enabled, and removes it when disabled. It also registers `IVAssistantExportPlugin`, which adds declared members' doc comments to an export (§11.5).
- **IVAssistantServer** — An autoload Node (root-level singleton). Reads config in `_ready()`, finds the project's lifecycle declaration (§11.6), and on its "initialized" signal loads suites and starts a TCP server. Processes commands in `_process()` on the main thread. Inert in a web export, which has no `TCPServer`. It refers to no project class.
- **IVAssistantAutomation** — Discovers the objects that declare automation members and serves `describe`, `get` and `call` (§4.1, §4.2, §11).
- **Built-in tools** — `IVAssistantWidgets` (list and operate widgets, §4.3) and `IVAssistantGodotTools` (screenshots, mouse, input actions, GUI inspection, §4.4–4.6). Both need only Godot.
- **IVAssistantTestSuite** — RefCounted base class for project-specific helper suites, loaded from the `[assistant_test_suites]` config section (§7.2). The default suites that bind to Core are **deprecated** (§4.7) and remain for projects that haven't moved to `describe`, `get` and `call`.

### 2.2 Component Diagram

```
EditorPlugin (editor/editor_plugin.gd)
  ├─ _enter_tree(): reads ivoyager_assistant.cfg, calls add_autoload_singleton()
  └─ IVAssistantExportPlugin: adds the doc-comment digest to exports (§11.5)

IVAssistantServer (autoload Node, root-level singleton)
  ├─ _ready(): reads config and command-line args, checks enabled/debug_only
  ├─ finds AUTOMATION_LIFECYCLE on an autoload and connects its signals (§11.6)
  ├─ on lifecycle "initialized": loads suites, starts TCPServer on 127.0.0.1:<port> (§7.3)
  ├─ on lifecycle "started": forwards to suites, re-evaluates deprecated token gating
  └─ _process(): polls TCP, reads JSON requests (or batches), dispatches, writes responses
       ├─ server: get_project_info, describe, get, call, quit
       ├─ IVAssistantAutomation: discovery, addresses, conversion, availability (§11)
       ├─ built-in: IVAssistantWidgets (§4.3), IVAssistantGodotTools (§4.4–4.6)
       └─ configured suites: project helpers, and the deprecated Core suites (§4.7)
```

### 2.3 Lifecycle

1. EditorPlugin registers `IVAssistantServer` as an autoload when the plugin is enabled.
2. On game start, `IVAssistantServer._ready()` reads config and command-line overrides (§7.3) and checks `enabled`/`debug_only`. Once every autoload is in the tree, it finds the first autoload whose script declares `AUTOMATION_LIFECYCLE` (§11.6; in Core, `IVStateManager`) and connects to the signals it names.
3. On "initialized" (Core: `core_initialized`): suites load, deprecated requirement tokens resolve (§7.5), and the TCP server starts listening. `describe`, `get` and `call` work from here on, on whatever exists and is available; so do suite methods that don't wait for the readiness gate.
4. On "started" (Core: `simulator_started`): forwarded to all suites, and deprecated `widget.*` / `runtime.*` tokens are re-evaluated. The readiness gate begins evaluating each frame.
5. **Readiness gate opens** after the project-supplied `ready_predicate` (default trivially true) has returned `true` for `min_ready_delay_frames` consecutive frames (default 10). `get_project_info` reports it as `ready`; suite methods that wait for it become available. See §7.3 and §7.4.
6. On "stopping" (Core: `about_to_free_procedural_nodes`): forwarded to all suites to clear references; the readiness gate re-arms. Declared objects freed now simply drop out of `describe`.
7. On "quitting" (Core: `about_to_quit`): the TCP server shuts down.

A project that declares no lifecycle is treated as initialized and started as soon as it runs.

For projects with `wait_for_start = true` (splash screens), there is a gap between steps 3 and 4 during which the client can connect, read `IVStateManager`, and call `IVStateManager.start` to bypass the splash screen (§8.2).

### 2.4 Security

- TCP server binds to `127.0.0.1` only (localhost)
- Server starts only when `OS.is_debug_build()` is true, unless overridden in config
- No authentication (localhost-only, debug-only)
- A client calls only members a class declares (§11.1), never an arbitrary method

## 3. Communication Protocol

### 3.1 Transport

- **TCP** on `localhost`, default port `29071`
- Port configurable via `ivoyager_assistant.cfg` under `[assistant]` section, or per process on the command line (§7.3), so several instances can run on one machine

### 3.2 Message Format

Newline-delimited JSON. Each message is a single line terminated by `\n`.

**Request:**
```json
{"id": 1, "method": "get", "params": {"object": "Timekeeper", "properties": ["time"]}}
```

**Success response:**
```json
{"id": 1, "result": {"time": 845888798.13}}
```

**Error response:**
```json
{"id": 1, "error": {"code": 1, "message": "Unknown method: get_stuff"}}
```

- `id` — Integer, echoed back to match request/response pairs. Optional; if omitted, response has no `id`.
- `method` — String, the API method name.
- `params` — Dictionary, method-specific parameters. Optional; defaults to `{}`.

**Batch:** a line may hold a JSON-RPC 2.0 batch, an array of requests. They execute in order, within one frame, and the response is an array of their responses in the same order; one request's error doesn't stop the rest. An empty array is an error. A batch is how a client composes several calls in one round trip, e.g. hide the GUI, take a screenshot and show the GUI again.

```json
[{"id": 1, "method": "call", "params": {"object": "IVStateManager", "method": "set_user_paused", "args": {"pause": true}}},
 {"id": 2, "method": "get", "params": {"object": "IVStateManager", "properties": "paused_by_user"}}]
```

### 3.3 Error Codes

| Code | Meaning |
|------|---------|
| 1 | Unknown method (or a member the object doesn't declare) |
| 2 | Invalid parameters (including an ambiguous address, which lists the candidates) |
| 3 | Not found (no object at the address, or no such body or widget) |
| 4 | Simulator not ready (a suite method before the readiness gate opens) |
| 5 | Not allowed (a declared member that isn't available now, or a widget that is disabled, hidden or refuses the value) |

## 4. API Methods

### 4.0 Project Info and Quit

#### `get_project_info`
Returns project identity, the server's lifecycle state, method names and optional context. Available as soon as the TCP server starts.

**Params:** none

**Result:**
```json
{
  "assistant_protocol_version": 4,
  "project_name": "I, Voyager - Planetarium",
  "project_version": "0.2.3.dev",
  "assistant_name": "I, Voyager - Planetarium",
  "started": true,
  "ready": true,
  "capabilities": ["call", "describe", "get", "list_widgets", "operate_widget", "quit", "..."],
  "methods": {"list_views": {"summary": "..."}, "...": {}},
  "gated_out": [{"method": "get_save_status", "unmet": ["autoload.IVSave"]}],
  "process_id": 12345,
  "port": 29071,
  "instance_id": "run-a"
}
```

- `started` — the lifecycle "started" signal has fired (§2.3); `ready` — the readiness gate is open (§7.4).
- `capabilities` — server methods, suite methods (built-in and configured) and suite feature flags (`"gui_inspection"`, `"mouse_target_id"`, `"widgets"`). What a project's classes offer is in `describe`, not here.
- `methods` — Map<method_name, {summary?}> for every suite method; `gated_out` — suite methods whose deprecated requirement tokens are unmet (§7.5).
- `assistant_name` defaults to `project_name` unless overridden in config. `context` (string, optional) is included if a context file is configured.
- `process_id` (int) is the game's OS process id — on Windows the game's own process, not the `_console.exe` wrapper a launcher starts — and `port` the port it listens on.
- `instance_id` (string, optional) echoes the `--assistant-instance` command-line argument (§7.3). A launcher that passes one can confirm it reached the process it started rather than another instance holding the port.
- **Deprecated:** while `CoreTestSuite` is loaded it adds `ok_to_start`, `wait_for_start` and `allow_time_setting`. Read `IVStateManager.ok_to_start`, `IVCoreSettings.wait_for_start` and `IVCoreSettings.allow_time_setting` instead.

#### `quit`
Shut down the application through the project's own quit, the method its lifecycle declaration names (Core: `IVStateManager.quit`), so the project frees what it built and reports leaks. Without one, `SceneTree.quit()`.

**Params:**
- `force` (bool, optional, default `false`) — If `true`, quit without a confirmation dialog. If `false`, may trigger a "Quit without saving?" dialog in projects that use one.

**Result:** `{"ok": true}`

The response is sent before quit executes (via `call_deferred`). `IVStateManager.quit` does nothing before the project can quit (early in boot); `describe` lists it under `unavailable` then.

### 4.1 Declared members: `get` and `call`

These read and call the members a class declares (§11.1), on the object an address names (§11.3). Arguments and results are converted by Godot's own type information (§11.4).

#### `get`
Reads declared properties of one object.

**Params:**
- `object` (address, required) — See §11.3.
- `properties` (string or array, optional) — Declared properties (or key properties) to read. Omit for all.

**Result:** `{"time": 845888798.13, "julian_day_number": 2461335}` — each property's value as JSON (§11.4).

#### `call`
Calls one declared method.

**Params:**
- `object` (address, required)
- `method` (string, required) — A declared method.
- `args` (object or array, optional) — Arguments by name (`{"new_speed_index": 3}`) or by position (`[3]`). An argument with a default may be omitted; an omitted argument before a given one takes its declared default.

**Result:** the method's return value as JSON; `null` for a method that returns nothing. A coroutine (a method that awaits, such as `IVSave.save_file`) answers `null` at its first `await` and finishes later; its description names what to poll.

Errors: an unknown address is code 3 (an ambiguous one code 2, listing the candidates); a member the object doesn't declare, code 1; a member its class says is not available now (§11.1), code 5; an argument that doesn't convert, code 2, naming it.

```json
{"id": 1, "method": "call", "params": {"object": "Timekeeper", "method": "set_time_from_date_clock_elements", "args": {"year": 2000, "month": 1, "day": 1}}}
{"id": 1, "result": true}
```

### 4.2 `describe`

A client's whole context in one call: every declared object and class, with each member's signature and description, the enum values members use, which members are unavailable now, and the user surface — the widgets a user can see and the input actions. All of it is generated from the running app, so anything absent is something the project does not offer, or does not offer now.

**Params:**
- `full` (bool, optional, default `false`) — Full class descriptions, rather than each class's first paragraph.
- `instances` (bool, optional, default `true`) — List each instance of a keyed class.
- `widgets` (bool, optional, default `true`) — Include the visible widgets (as `list_widgets` with `visible_only`).
- `actions` (bool, optional, default `true`) — Include the input actions (as `list_actions`).

**Result (abbreviated):**
```json
{
  "objects": {
    "Timekeeper": {
      "class": "IVTimekeeper",
      "description": "Maintains simulator \"time\" (TT; J2000 epoch), Julian Day Number, ...",
      "surface": "test",
      "methods": {
        "set_time": {"description": "Sets `time` and emits `time_set`. ...",
            "args": [{"name": "new_time", "type": "float"}], "returns": "void"}
      },
      "properties": {"time": {"type": "float", "description": "Terrestrial Time (TT) ..."}}
    },
    "IVStateManager": {"class": "IVStateManager", "...": "...", "unavailable": ["start", "exit"]}
  },
  "classes": {
    "IVBody": {"class": "IVBody", "key": ["name"], "count": 200,
        "instances": [{"name": "STAR_SUN"}, {"name": "PLANET_EARTH"}], "methods": {}, "properties": {}},
    "IVOrbit": {"class": "IVOrbit", "reached_by": ["IVBody.orbit", "IVBody.get_orbit()"], "...": "..."}
  },
  "enums": {"IVBody.BodyFlags": {"BODYFLAGS_STAR": 1, "...": 2}, "IVCamera.CameraFlags": {}},
  "widgets": [{"widget": {"class": "IVPauseButton"}, "family": "button", "name": "Pause", "state": {"pressed": false}}],
  "actions": {"toggle_pause": ["Space"], "...": []}
}
```

- `objects` — single objects by address: an autoload's name, a role a declaring object names (§11.2), or a class with one instance. `classes` — classes with several instances (keyed, §11.3), and classes that declared members hold or return (`reached_by`), which a client reads as values or addresses with `via`.
- A method's `args` list each argument's `name`, `type`, `optional`, and `default` where the default is known. Types read as Godot names them: `"float"`, `"Vector3"`, `"Array[StringName]"`, `"IVBody"`, an enum's `"Class.Enum"`, `"Variant"`, `"void"`.
- `description` is the member's or class's doc comment (§11.5). A Godot-native member a class declares (`name`, `global_position`, `visible`) has none.
- `surface` is `"user"` for a `Control` — what a user operates or sees — and `"test"` otherwise. The user surface is all an accessibility client should use; the test surface reaches state however the GUI looks.
- `unavailable` — declared members the class says can't be used now (§11.1). For a keyed class, per instance.
- `enums` — each enum a member's type names, and each enum constant of a declaring class, by name.

### 4.3 Widgets

The user surface: the `Control`s a user operates, operated the way a user operates them so each widget's own handler runs. Capability `widgets`. See §11.7 for how a widget names, identifies and describes itself.

#### `list_widgets`
**Params:**
- `root` (string, optional, default `"/root"`) — Node path to list under.
- `visible_only` (bool, optional, default `false`) — Only widgets visible now.

**Result:**
```json
{
  "widgets": [
    {"widget": {"class": "IVNavButton", "body_name": "PLANET_SATURN"}, "class": "IVNavButton",
     "family": "button", "name": "Saturn", "state": {"pressed": false}, "enabled": true, "visible": true},
    {"widget": {"class": "IVSpeedButtons"}, "class": "IVSpeedButtons", "family": "composite",
     "name": "Game Speed", "state": {"value": 2, "options": ["1x", "10x", "100x"]}, "enabled": true, "visible": true},
    {"widget": {"body_flags": 64, "class": "IVHUDsCheckBox", "hud_type": "ORBITS", "sbg_aliases": []},
     "class": "IVHUDsCheckBox", "family": "button", "name": "Planets: Show Orbit",
     "state": {"pressed": true}, "enabled": true, "visible": false,
     "opened_by": {"class": "IVPanelButton", "name": "HUDsButton"}}
  ],
  "count": 3
}
```

- `widget` — the widget's address, to pass to `operate_widget`: its declared key, else its class when it has one instance, else its node path.
- `family` — `button`, `option`, `range`, `tabs`, `foldable`, `line_edit`, `text_edit` or `composite` (§11.7). `state` — what a user sees: `pressed` for a toggle, `value`/`min`/`max`/`step` for a range, `current_tab`/`tabs`, `folded`/`title`, `selected`/`items`, `text`; a composite's `value` and `options`.
- `name` and `description` are translated, as the user sees them. `controls` lists what a widget opens; `opened_by` names, for a hidden widget, the widget that shows it.

#### `operate_widget`
**Params:**
- `widget` (address, required) — From `list_widgets`: `{"class": ..., <key>: ...}`, `{"path": ...}`, or a class name with one instance.
- By family: `pressed` (bool, optional, toggle buttons: press only if it would change), none (other buttons: press), `value` (range, composite), `tab` (index or title), `folded` (bool), `item` (index or text), `text` (line or text edit) and `submit` (bool, line edit).

**Result:** `{"ok": true, "widget": <address>, "state": {...}}` — the state just after. A widget that updates itself on the next frame (the focal-length spin box, a popup button released by its popup) shows the change only on a later read.

Errors: a hidden widget, code 5, naming the widget that shows it; a disabled or non-editable one, code 5; a composite that refuses the value, code 5; an address matching several, code 2, listing them. Nothing is clicked at a screen position, so overlapping controls, GUI scale and headless runs don't matter.

### 4.4 Screenshot

#### `screenshot`
Capture the root viewport, what is on screen, to a PNG file.

**Params:**
- `path` (string, required) — Output file path (must be a valid writable path)
- `redraw` (bool, optional, default `false`) — Render a frame first. A batch that hides something before the screenshot needs it, since a batch runs within one frame.

**Result:**
```json
{"ok": true, "path": "C:/tmp/screenshot.png", "size": [1920, 1080]}
```

To capture without the GUI, compose it: `IVShowHideUI.show_hide_gui(false, false)`, `screenshot` with `redraw`, `IVShowHideUI.show_hide_gui(false, true)`, in one batch. `IVBodyHUDsState.set_huds_hidden(true)` hides the 3D HUDs (orbit lines, names, symbols, small-body points) the same way; read `huds_hidden` back rather than assume it. (Deprecated: `CoreTestSuite`'s `screenshot` also takes `hide_gui`, §4.12.)

### 4.5 Mouse, Input Actions and Projection

Every position these take or return is in **window pixels**: the pixels of a `screenshot` image. On a hi-DPI screen a project's display scale makes them finer than the GUI's logical pixels (2.5 to one at 250% Windows scaling), and the methods convert between the two so a client never has to. Capability `mouse_target_id`.

#### `warp_mouse`
Synthesize an `InputEventMouseMotion` at a window pixel, updating whatever follows mouse events (in Core, `IVWorldController.mouse_position`) the way an OS mouse event would, without moving the OS cursor.

**Params:** `position` (array, required) — `[x, y]`

**Result:** `{"ok": true, "position": [640.0, 360.0]}`

#### `get_mouse_position`
The viewport's mouse position. This is the OS cursor; `warp_mouse` doesn't move it.

**Result:** `{"position": [830.0, 412.0]}`

#### `project_to_screen`
Project a 3D position to a window pixel through the active `Camera3D`.

**Params (exactly one of `node` or `world_position`):**
- `node` (address or node path) — A `Node3D`, e.g. `{"class": "IVBody", "name": "PLANET_MARS"}`; projects its `global_position`.
- `offset` (array, optional, with `node`) — Added to the node's position. A client projects where a body will be by adding how far it moves up its parent chain (`IVBody.get_position_vector(time)` less its value now, summed over `parent`s), which lands on its orbit line; and an asteroid by `IVSmallBodiesGroup.get_member_position(index)` from the group's `get_primary()`.
- `world_position` (array) — `[x, y, z]` in scene-tree world coordinates.

**Result:**
```json
{"position": [820.5, 412.0], "on_screen": true, "behind_camera": false, "world_position_used": [-329046784.0, 235556144.0, -161255408.0]}
```

`on_screen` is `true` only when `behind_camera` is `false` and the pixel is inside the viewport rect. (Deprecated: `MouseTargetIdSuite`'s version also takes `body` and `time`, §4.13.)

**Hover identification.** What the user sees under the mouse is `IVMouseTargetLabel`'s declared `text` and `visible` (§4.1), whatever identifies it — tests written against the label stay valid when the identifier underneath is replaced. A workflow: frame the target (`IVViewManager.set_table_view`, or `IVCameraHandler.move_to_by_name`); make its HUD visible (an orbit line, `IVBodyHUDsState.set_all_orbits_visibility`; an asteroid's points, `IVSBGHUDsState.change_symbols_visibility`); hide the GUI, since a panel over the pixel takes the mouse from the world; project; `warp_mouse`; wait ~250–400 ms (the fragment identifier runs an 8-frame cycle); read `IVMouseTargetLabel.text`; restore what you changed. `tools/assistant_test.py` does all three: a body, an orbit line, an asteroid point.

#### `list_actions`
The project's input actions, the user's keyboard surface, with the events bound to each. Godot's own `ui_*` actions are left out.

**Params:** `include_ui` (bool, optional, default `false`)

**Result:** `{"actions": {"toggle_pause": ["Space"], "incr_speed": ["Period"], "...": []}}`

A project may declare display names (Core: `IVInputMapManager.action_texts`). (Deprecated: while `ControlSuite` is loaded, `list_actions` returns its own form, display names by action, §4.9; `describe`'s `actions` is always this form.)

#### `press_action`
Emulates a user hotkey press. Injects the action's `InputEventKey` into Godot's input pipeline via `Input.parse_input_event()`, so it flows through `_shortcut_input()` handlers exactly like a physical key press. Both press and release events are injected.

**Params:** `action` (string, required) — An action from `list_actions` (e.g. `"toggle_pause"`).

**Result:** `{"ok": true, "action": "toggle_pause"}`

Note: camera movement actions (e.g. `camera_up`) are designed for sustained key holds; an instant press and release has negligible effect. `toggle_all_huds` is a toggle, so what it leaves on screen depends on whether the HUDs were already hidden; `IVBodyHUDsState.set_huds_hidden` is deterministic.

### 4.6 GUI Inspection

Generic scene tree inspection methods that work on any GUI node without per-widget custom code. Available before the simulator starts. Capability: `gui_inspection`. For what a user can operate, `list_widgets` (§4.3) is the better start; these read what is displayed.

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

**Result:** Nested dictionary tree. Each node includes `name`, `class`, `visible`, and a `Control`'s `accessibility_name` and `accessibility_description` when set. Class-specific properties are included automatically: `text` for Labels, `current_tab`/`tab_names` for TabContainers, `title`/`folded` for FoldableContainers.

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

**Timing note:** Some projects populate GUI content asynchronously (e.g., via deferred calls or background threads). `read_node_text` reads the current display state — it does not trigger or wait for updates. If labels are empty, the data may not yet have populated. Callers should ensure the relevant GUI is active and data has had time to load (e.g., select with `SelectionManager.select_by_name`, wait ~2 seconds, then inspect).

**Recommended AI workflow** for "test X for sensible output":
1. `get_project_info` — confirm `ready`
2. `call` `SelectionManager.select_by_name` — navigate to entity with data
3. Wait ~2 seconds for data population
4. `find_nodes` with `script_class` — discover the node path
5. `read_node_text` with that path — harvest visible text
6. Analyze entries for non-empty values, reasonable numeric ranges, correct section titles

### 4.7 Deprecated suite methods

The default suites below bind to Core classes and predate §11. Core's classes now declare the same state and controls, so these remain only for projects that haven't moved, and will be removed. A new client uses `describe`, `get`, `call` and the widgets; this table is the migration.

| Deprecated method | Instead |
|---|---|
| `get_state` | `get` `IVStateManager` (`started`, `running`, `paused_tree`, `paused_by_user`, `building_system`), `IVGlobal` (`times`, `date`, `clock`) and `SpeedManager` (`speed_index`, `reversed_time`); `SpeedManager.get_speed_name` |
| `start_game` | `call` `IVStateManager.start` (available while `ok_to_start`) |
| `get_time` | `get` `Timekeeper` (`time`, `julian_day_number`), `IVGlobal` (`date`, `clock`, `times`) |
| `get_selection` | `get` `SelectionManager.selection`; `SelectionManager.get_name`, `get_gui_name`, `get_body_flags` |
| `get_camera` | `get` `IVCamera` (`target`, `flags`, `view_position`, `view_rotations`, `is_camera_lock`) |
| `list_bodies` | `describe`'s `IVBody` instances; filter by `get` `flags` against `enums["IVBody.BodyFlags"]` |
| `get_body_info` | `get` `{"class": "IVBody", "name": ...}` (`flags`, `mean_radius`, `gravitational_parameter`, `parent`, `satellites`) |
| `get_body_position`, `get_body_state_vectors` | `call` `IVBody.get_position_vector`, `get_state_vectors` with `time` |
| `get_body_orbit` | `get` the body's `orbit` (a value with its class), or `call` on `{"class": "IVBody", "name": ..., "via": "orbit"}`: `get_semi_major_axis_at_time` and the like |
| `get_body_distance` | Compose from positions summed up the parent chain |
| `select_body`, `select_navigate` | `call` `SelectionManager.select_by_name`, `select_up`, `select_next_planet`, ... (available when there is somewhere to go) |
| `set_pause` | `call` `IVStateManager.set_user_paused`, or operate `IVPauseButton` |
| `set_speed` | `call` `SpeedManager.change_speed`, `increment_speed`, `decrement_speed`, `set_real_time_speed`, or operate `IVSpeedButtons` |
| `set_time` | `call` `Timekeeper.set_time`, `set_time_from_date_clock_elements`, `set_operating_system_time_sync`, or operate `IVTimeSetter` |
| `move_camera` | `call` `CameraHandler.move_to_by_name` / `move_to` (`camera_flags` by `IVCamera.CameraFlags` names); prefer views |
| `set_camera_fov` | `call` `IVCamera.set_focal_length`, `set_field_of_view`, `get_focal_length`, or operate `IVFocalLengthControl` |
| `show_hide_gui` | `call` `IVShowHideUI.show_hide_gui` |
| `set_huds`, `get_huds`, `set_class_huds`, `set_all_body_orbits_visibility`, `set_body_orbit_visible_flags` | `get` and `call` `BodyHUDsState` and `SBGHUDsState`, or operate the `IVHUDsCheckBox` widgets |
| `list_views`, `apply_view`, `list_cached_views`, `apply_cached_view` | `get` `ViewManager` (`table_views`, `cached_views`); `call` `set_table_view`, `set_view`; or operate `IVViewButton` |
| `get_options`, `set_option` | `call` `IVSettingsManager` (`get_setting_keys`, `get_setting`, `get_default`, `change_setting` with `suppress_caching`, ...); `IVOptionsPopup.get_option_enumeration` names a dropdown's values |
| `screenshot` with `hide_gui` | A batch: `IVShowHideUI.show_hide_gui`, `screenshot` with `redraw`, show again (§4.4) |
| `project_to_screen` with `body` | `project_to_screen` with `node` and `offset` (§4.5) |
| `get_hover_target` | `get` `IVMouseTargetLabel` (`text`, `visible`) |
| `list_small_body_groups`, `project_small_body_to_screen`, `set_small_body_points_visibility` | `describe`'s `IVSmallBodiesGroup` instances and their declared members; `SBGHUDsState.change_symbols_visibility` |
| `save_game` | `call` `IVSave.quicksave`, `autosave`, or `save_file` with `save_type` and `path`; poll `get` `IVSave.is_saving` |
| `load_game` | `call` `IVSave.quickload`, or `load_file` with `path`; poll `get` `IVSave.is_loading`, then `IVStateManager.started` |
| `get_save_status` | `get` `IVSave` (`is_saving`, `is_loading`, `directory`, `file_extension`); `call` `has_file`, `get_last_modified_file_path` with the directory |

`press_action`, `warp_mouse` and the GUI inspection methods were in these suites and are now built in, unchanged (§4.5, §4.6).

### 4.8 Deprecated: State and Body Queries (`StateQuerySuite`)

Deprecated (§4.7). Each reads Core state the classes now declare.

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

### 4.9 Deprecated: Controls, GUI and HUD Visibility (`ControlSuite`)

Deprecated (§4.7). `press_action` moved to the built-in tools (§4.5).

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
Low-level camera move. **Prefer views (`IVViewManager.set_table_view`) for the common "frame a body" case** — they bind to the same Core entry point the GUI view buttons use and need no hand-built perspective-distance vector. Use `move_camera` only for explicit per-axis control.

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

Small-body group points have their own setter, `set_small_body_points_visibility` (§4.13).

#### `list_actions`
Replaces the built-in `list_actions` (§4.5) while this suite is loaded. Returns all registered input actions with their display names. Actions are defined by `IVInputMapManager` and include display toggles, camera controls, selection navigation, time controls, and administrative actions.

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

### 4.10 Deprecated: Views (`ViewSuite`)

Deprecated (§4.7). Named built-in views are the GUI-parity way to frame the camera and (optionally) reset HUD/time state. Each maps to a row in `tables/views.tsv` and is the exact target of a default `IVViewButton` (`pressed → IVViewManager.set_table_view`). See §10 (Core surface classes). These are the standard "frame a body" controls — prefer them over `move_camera`.

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

### 4.11 Deprecated: User Settings (`SettingsSuite`)

Deprecated (§4.7). User settings are `IVSettingsManager`'s: those the Options popup (`IVOptionsPopup`) shows, and any a project keeps out of it. They exist before the simulator starts, so these methods work from a splash screen too.

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

### 4.12 Deprecated: State, Start, Screenshot and Save/Load (`CoreTestSuite`)

Deprecated (§4.7). Also adds `ok_to_start`, `wait_for_start` and `allow_time_setting` to `get_project_info`. Save/load is replaced by the Save plugin's own declarations on `IVSave` (§4.7).

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

#### `start_game`
Start the simulation in projects with splash screens (`wait_for_start = true`); `IVStateManager.start` does it now. Returns error if already started or not ready (assets still loading).

**Params:** none

**Result:** `{"ok": true}`

#### `screenshot` (with `hide_gui`)
Replaces the built-in `screenshot` (§4.4) while this suite is loaded, adding one parameter:

- `hide_gui` (bool, optional, default false) — Hide the GUI (`IVGlobal.show_hide_gui_requested`), render and capture as the built-in does with `redraw`, then show the GUI again.

Without `hide_gui` it hands the request to the built-in unchanged.

#### Save/load

These methods are only available when the `ivoyager_save` plugin is present and enabled. They appear in `get_project_info` capabilities only when detected. If called without the plugin, they return error code 5 ("Save plugin not available").

Save and load operations are **asynchronous**. The methods return `{"ok": true}` immediately. Poll `get_state` to detect completion via the `is_saving` / `is_loading` fields.

#### `save_game`
Trigger a save operation. Requires the readiness gate open.

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
Trigger a load operation. Requires the readiness gate open.

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

### 4.13 Deprecated: Mouse Hover and Small Bodies (`MouseTargetIdSuite`, `SmallBodiesIdSuite`)

Deprecated (§4.7). Hover-test helpers that bind to Core. `MouseTargetIdSuite` (`project_to_screen`, `get_hover_target`; capability `mouse_target_id`) and `SmallBodiesIdSuite` (`list_small_body_groups`, `project_small_body_to_screen`, `set_small_body_points_visibility`; capability `small_bodies_id`), which is present only in projects that load small-body groups. `warp_mouse` moved to the built-in tools (§4.5); §4.5 also gives the hover workflow on declared members.

`MouseTargetIdSuite` intentionally observes [`IVMouseTargetLabel.text`](../ivoyager_core/ui/mouse_target_label.gd) — the label the user actually sees — rather than any specific identifier API. Tests written against these methods remain valid across replacement of the underlying identification mechanism (e.g. a future Compositors-based system replacing `IVFragmentIdentifier`).

Every position these methods take or return is in window pixels, as in §4.5.

#### `project_to_screen`
Replaces the built-in `project_to_screen` (§4.5) while this suite is loaded, adding `body` and `time`; without `body` it hands the request to the built-in. Use to find good test coordinates for hover assertions: project a body for body-pixel hover, or a body at a future time to land on its orbit line. Asteroids have their own method, `project_small_body_to_screen`.

**Params (exactly one of `body`, `node` or `world_position` required):**
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
Show or hide one group's points. Core shows no group's points by default, and a hidden point can't be identified under the mouse, so an SBG-point hover test turns its group on first. Visibility persists across sessions like the other HUDs (§4.9).

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
1. Frame a vantage point (`move_camera`, or a view) that puts the test target on-screen. Make the target's HUD visible: its orbit line for an orbit-line test (`set_all_body_orbits_visibility`), its group's points for an asteroid test (`set_small_body_points_visibility`).
2. Wait ~1 s for camera and HUDs to settle.
3. `project_to_screen` with `body` (or `project_small_body_to_screen`) to get the target's projected pixel.
4. `warp_mouse` to that pixel (or a small offset for orbit-line tests).
5. Sleep / poll briefly; call `get_hover_target` and assert on `text`.
6. Restore any HUD visibility you changed.

## 5. Dependencies

The server, `IVAssistantAutomation` and the built-in tools depend on Godot alone. They find the project's objects through the convention of §11 and never name a project class; the last Core knowledge, the lifecycle signals, is read from `IVStateManager`'s own `AUTOMATION_LIFECYCLE` declaration (§11.6).

Only the deprecated suites (§4.7) and their requirement-token vocabulary (§7.5, `IVAssistantRequirementTokens`) depend on Core: on `IVStateManager`, `IVGlobal`, `IVCoreSettings`, `IVBody`, `IVOrbit`, `IVSelectionManager`, `IVSpeedManager`, `IVTimekeeper`, `IVCameraHandler`, `IVCamera`, `IVViewManager`, `IVView`, `IVBodyHUDsState`, `IVSBGHUDsState`, `IVSmallBodiesGroup`, `IVSettingsManager`, `IVOptionsPopup`, `IVInputMapManager` and `IVMouseTargetLabel`, and (duck-typed, optional) on the Save plugin's `IVSave`. `IVAssistantTestSuite`'s `parse_body()` and `get_global_position()` are deprecated with them.

## 6. Threading and Safety

- All TCP I/O and command processing runs on the main thread in `_process()`
- This is safe for scene tree access but limits throughput to frame rate (~60 Hz)
- For a testing/accessibility interface, sub-16ms latency is adequate
- The server processes all pending complete messages each frame (not just one); a batch runs within one frame
- A declared method runs on the main thread as any GUI handler does; a class whose members are not main-thread safe gates them in `is_automation_available()` or doesn't declare them

## 7. Configuration

`ivoyager_assistant.cfg` (abbreviated):

```ini
[assistant_autoload]
IVAssistantServer="../assistant_server.gd"

[assistant_test_suites]
; DEPRECATED Core suites (§4.7), one line each:
StateQuerySuite="res://addons/ivoyager_assistant/test_suites/state_query_suite.gd"

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

The `[assistant_test_suites]` section registers `IVAssistantTestSuite` subclasses, each adding methods to the server: helpers for what no class can declare, specific to one project. Each entry maps a suite name to a GDScript file path. The server loads these on the lifecycle "initialized" signal, calls `_init_test_suite()` on each, and adds their `get_method_names()` to the dispatch table. A suite's method may replace a built-in tool of the same name (the deprecated suites do, to keep their own parameters), never a server method.

**Default suites (all deprecated, §4.7):**

| Suite | Methods |
|---|---|
| `StateQuerySuite` | `get_time`, `get_selection`, `get_camera`, `list_bodies`, `get_body_info`, `get_body_position`, `get_body_orbit`, `get_body_distance`, `get_body_state_vectors` |
| `ControlSuite` | `select_body`, `select_navigate`, `set_pause`, `set_speed`, `set_time`, `move_camera`, `set_camera_fov`, `show_hide_gui`, `list_actions`, `set_all_body_orbits_visibility`, `set_body_orbit_visible_flags`, `set_huds`, `get_huds`, `set_class_huds` |
| `ViewSuite` | `list_views`, `apply_view`, `list_cached_views`, `apply_cached_view` |
| `SettingsSuite` | `get_options`, `set_option` |
| `CoreTestSuite` | `get_state`, `start_game`, `screenshot`, `save_game`, `load_game`, `get_save_status` |
| `MouseTargetIdSuite` | `project_to_screen`, `get_hover_target` |
| `SmallBodiesIdSuite` | `project_small_body_to_screen`, `list_small_body_groups`, `set_small_body_points_visibility` |

**Override examples** (in `ivoyager_override.cfg` or `ivoyager_override2.cfg`):

```ini
[assistant_test_suites]
; Remove a suite entirely:
StateQuerySuite=null

; Add a project suite alongside the defaults:
MyProjectTests="res://tests/my_project_tests.gd"
```

Setting a suite to `null` or `""` removes it. Adding a new key registers a new suite. If two configured suites register the same method name, the last one loaded wins (with a warning).

**Creating a suite:**

Extend `IVAssistantTestSuite` and override:
- `get_method_names()` — The method names your suite handles.
- `get_method_summaries()` — Optional Map<method_name, String> of one-line summaries surfaced in the `methods` field of `get_project_info`.
- `is_applicable()` — Return `false` to opt out of the entire suite, e.g. for a plugin the project lacks.
- `get_capabilities()` — Additional capability strings (feature-group identifiers) that aren't method names.
- `dispatch(method, params)` — Handle method calls, return result or `_error` dict.
- `requires_sim_started()` — Return `false` if the methods work before the readiness gate opens (default: `true`).
- `_on_simulator_started()` / `_on_about_to_free()` — Called on the lifecycle "started" and "stopping" signals.
- Deprecated: `get_method_requirements()` (§7.5) and `add_project_info()`.

The suite receives the server node via `_init_test_suite(server)`; use `_server.get_viewport()` for viewport access and `_server.is_ready()` for the readiness gate (§7.4). `resolve(address)` finds the object a client's address names (§11.3); `parse_vector3()` and `to_window_pixels()` are static helpers.

### 7.3 Runtime Settings

The `[assistant]` section controls runtime behavior:

- `port` — TCP listen port (default: 29071)
- `enabled` — Master enable/disable (default: true). When false, the autoload node exists but does not start the TCP server.
- `debug_only` — If true, server only starts when `OS.is_debug_build()` is true (default: true). The export digest of doc comments (§11.5) is added only to exports in which the server can run.
- `assistant_name` — Display name for the assistant persona (default: empty, uses project name from ProjectSettings)
- `context_file` — Path to a text file (`res://` relative) with project-specific context for AI clients (default: empty)
- `min_ready_delay_frames` — Number of consecutive frames the project's `ready_predicate` must return `true` (after the lifecycle "started" signal) before the readiness gate opens (default: 10). Allows projects with deferred main-thread work after start (e.g. cross-thread initialization arriving via `call_deferred`) to settle before save/load and similar operations are permitted. See §7.4.

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

Projects with cross-thread or deferred initialization that continues past the simulator's start can supply a readiness predicate that the server polls each frame:

```gdscript
IVAssistantServer.ready_predicate = func() -> bool:
	return MyProject.is_initialization_complete
```

The readiness gate stays closed until the predicate has returned `true` for `min_ready_delay_frames` consecutive frames (counted from the first frame the predicate returns `true`, not from the "started" signal). If the predicate flips back to `false` while counting, the countdown resets. Once the gate has opened, it stays open until the lifecycle "stopping" signal (e.g. during a load).

The default predicate is trivially `true`, so projects that don't set `ready_predicate` get only the `min_ready_delay_frames` buffer after the start.

`get_project_info` reports the gate as `ready`. It gates suite methods (`requires_sim_started()`), not declared members, whose classes own their gates (§11.1). Suites that opt out of the suite-wide gate can still consult it per method via `IVAssistantServer.is_ready()`; `CoreTestSuite` does for `save_game` and `load_game`.

### 7.5 Requirement-Token Vocabulary (deprecated)

`IVAssistantTestSuite.get_method_requirements()` returns a Map<method_name, Array[String]> of tokens from the closed vocabulary in `IVAssistantRequirementTokens.KNOWN_TOKENS`. Unknown tokens `push_error` at suite load and are dropped. A method with an unmet token is left out of the dispatch table — calling it returns `ERR_UNKNOWN_METHOD`, identical to a never-implemented method — and is listed under `gated_out` in `get_project_info` with the unmet tokens.

This is deprecated with the suites that use it: under §11 a class gates its own members in `is_automation_available()`, and nothing is assumed available that its class doesn't say is.

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
| `widget.MouseTargetLabel` | `IVMouseTargetLabel` reachable under `program.TopUI` after start |
| `runtime.IVSmallBodiesGroup` | `IVSmallBodiesGroup.small_bodies_groups` non-empty after start |

`core.*`, `program.*`, `autoload.*`, and `body_table.*` tokens resolve when suites load. `widget.*` and `runtime.*` tokens resolve false until the lifecycle "started" signal, when gating refreshes once.

## 8. Cross-Project Compatibility

The plugin is designed as a git submodule usable across any I, Voyager project, and any Godot project that declares automation members. Enable the plugin in Project Settings → Plugins — no project-level config changes are needed.

### 8.1 Feature Availability

What a project offers is what its classes declare and say is available now, and `describe` (§4.2) reports exactly that: a missing object or member is one the project lacks; a member under `unavailable` exists but can't be used now (a network client's time setting, a selection step with nowhere to go, `IVStateManager.start` once started). Calling either is an error (codes 3, 1 and 5), never a silent no-op. Every Core program object a project replaces keeps its role name (`"SpeedManager"`), and a replacement class declares its own members (§11.1).

`get_project_info`'s `capabilities` lists server and suite methods only. For the deprecated suites, `gated_out` explains which are unavailable and why (§7.5).

The protocol version is reported as `assistant_protocol_version`: `4` added `describe`, `get`, `call`, the widget methods, batches, `ready`, and the lifecycle declaration; `3` added `process_id`, `port` and `instance_id`.

### 8.2 Splash Screen Handling

Projects with `IVCoreSettings.wait_for_start = true` display a splash screen before starting the simulation. The TCP server starts on the lifecycle "initialized" signal, before the splash screen, so a client can:

1. Connect and call `get_project_info` and `describe` to discover the project
2. `get` `IVStateManager` (`ok_to_start`, `started`) and `IVCoreSettings.wait_for_start`
3. `call` `IVStateManager.start` once it is available, to start the simulation (bypassing the splash screen), then poll `get_project_info` until `ready`

### 8.3 Project Identity

Projects can customize the assistant's identity via config:
- `assistant_name` — Gives the assistant a project-specific name
- `context_file` — Points to a text file with background information, personality guidelines, or project-specific instructions for AI clients

## 9. Generic Test Sequence

This section describes how to launch, connect, and run the generic tests that the Assistant plugin provides. These tests verify basic simulation functionality and work across I, Voyager projects with the plugin enabled.

### 9.1 Launch

Run the Godot project from the command line in debug mode, with `--path` pointing to the project directory:

```
<godot_console_exe> --path .
```

Portable Godot executables are in the parent directory of the project (`../`). Use the newest `Godot_v*_console.exe` of the major version (4.6, 4.7, ...) the project's `config/features` names; `python tools/godot_executable.py <project>` prints it. Don't choose by version number or file date alone: a build of another major rewrites `project.godot`, import files and scenes for its own version when it opens the project. The console variant outputs to stdout/stderr, which is useful for observing errors during testing. To run alongside another instance of the project, give each its own port (§7.3).

### 9.2 Connect

Connect via TCP to `127.0.0.1:29071`, or the port passed with `--assistant-port`. The server starts listening on the lifecycle "initialized" signal, which may take a few seconds after launch. Retry the connection with a short delay (e.g., 2 seconds) if refused.

### 9.3 Test Steps

Execute these steps in order:

1. **Discover:** Call `get_project_info` (protocol version 4 or later) and `describe`.
2. **Start the simulation:** If `IVCoreSettings.wait_for_start` is `true` and `IVStateManager.started` is `false`, call `IVStateManager.start`. Then poll `get_project_info` until `ready`, and `describe` again: bodies and their widgets exist now.
3. **Verify state:** `get` `IVStateManager.started`, `IVGlobal.date`, `SelectionManager.selection`, `IVCamera.target`, and confirm reasonable values.
4. **Exercise controls:** Find planets among `describe`'s `IVBody` instances by their flags; `SelectionManager.select_by_name` `"PLANET_MARS"`; `CameraHandler.move_to_by_name` `"PLANET_EARTH"`; pause and unpause through `IVStateManager.set_user_paused` (one batch); `SpeedManager.change_speed`.
   - **Widgets:** operate `IVPauseButton` and `IVSpeedButtons` and confirm the state they change.
   - **Mouse hover** (if the game renders): identify a body, an orbit line and an asteroid point under the mouse, as in §4.5.
5. **Save/load cycle** (if `save_game` and `load_game` are in capabilities; deprecated, §4.12): Call `save_game`, then poll `get_state` until `is_saving` is `false`. Call `load_game`, then poll `get_state` until `is_loading` is `false` and `started` is `true`.
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

The script skips a step whose object or member the project doesn't declare. Exit code is 0 on success, 1 on failure. Its `AssistantClient` has `describe()`, `get()`, `invoke()` (a `call`) and `batch()` helpers, raising `AssistantError` on an error response, for client scripts of a project's own.

`tools/orbit_accuracy_test.py` uses the same client and launcher to check body positions against JPL Horizons reference vectors; its module docstring is its specification.

### 9.4 Key Notes

- **Readiness:** `ready` in `get_project_info` says the readiness gate is open. Suite methods return error code 4 until it does; declared members answer whatever exists, so before the start a body simply isn't found yet.
- **Unavailable is not missing:** code 5 means the member exists but its class says it can't be used now; code 1, that the class doesn't declare it.
- **Async save/load:** `save_game` and `load_game` return `{"ok": true}` immediately. Poll `get_state` to check `is_saving`/`is_loading` for completion. During load, objects freed and rebuilt drop out of `describe` until the new ones exist.
- **Per-frame processing:** Requests are processed once per frame (~60 Hz). A batch runs within one frame, so its calls see each other's effects but no frame renders between them; pass `redraw` to a `screenshot` that follows a change in the same batch.
- **Persisted state:** HUD visibility and views persist across sessions, and a project may restore them at startup, so a test sets the state it depends on explicitly and restores what it changed. `IVSettingsManager.change_setting` writes the settings file unless `suppress_caching` is `true`.

## 10. Core surface classes (layering principle)

A class declares, for an automated action, **the same entry point its GUI widget calls, at the same abstraction level.** When a control exists in the GUI, the declared method is the one the widget's handler calls — not a lower-level primitive. This keeps an automated action and a user's button click semantically identical and on the same code path, which serves both goals in §1: faithful testing, and accessibility as genuine GUI substitution. (Operating the widget itself, §4.3, is the same path by construction.)

Declaring a member below that surface is a deliberate, marked exception, and its doc comment says so. There are two in Core:

- `IVCameraHandler.move_to` / `move_to_by_name` bypass the view layer and take a perspective-distance `view_position`. Camera framing should normally go through `IVViewManager.set_table_view`, exactly what the GUI view buttons do.
- The bulk HUD setters (`IVBodyHUDsState.set_all_orbits_visibility`, `set_orbit_visible_flags`; `IVSBGHUDsState.change_symbols_visibility`) set visibility by raw flags or through a lower setter, which no GUI widget does. The per-class setters are the widget-level path.

| Control group | GUI widget script | Declared Core member |
|---|---|---|
| Apply named view | `ui_widgets/view_button.gd` (`IVViewButton`) | `IVViewManager.set_table_view` (default views); `IVViewManager.set_view` (user/cached) |
| Select / navigate body | `ui_widgets/nav_button.gd`, `selection_buttons.gd` | `IVSelectionManager.select_by_name` / navigation methods |
| Simulation speed | `ui_widgets/speed_buttons.gd` | `IVSpeedManager.change_speed`, `increment_speed`, `decrement_speed` |
| Pause | `ui_widgets/pause_button.gd` | `IVStateManager.set_user_paused` |
| Time | `ui_widgets/time_setter.gd` | `IVTimekeeper.set_time_from_date_clock_elements` / related |
| Camera zoom | `ui_widgets/focal_length_control.gd` | `IVCamera.set_focal_length` (and `set_field_of_view`) |
| Camera tracking | `ui_widgets/track_ckbxs.gd` | `IVCamera` move with a tracking flag, through the widget's value interface |
| Camera (low-level) | — (no GUI widget hand-supplies a `view_position`) | `IVCameraHandler.move_to` / `move_to_by_name` — **below the view layer, a marked exception** |
| Hide all HUDs | `ui_widgets/hide_huds_button.gd` (`IVHideHUDsButton`) | `IVBodyHUDsState.set_huds_hidden` |
| HUD visibility by class | `ui_widgets/huds_checkbox.gd` (`IVHUDsCheckBox`) | `IVBodyHUDsState` `set_name_visibility` / `set_symbol_visibility` / `set_orbit_visibility`; `IVSBGHUDsState` `set_visible_symbols_groups` / `set_visible_orbits_groups` |
| HUD visibility, bulk or raw | — (the checkboxes set one class or group) | `IVBodyHUDsState` `set_all_orbits_visibility` / `set_orbit_visible_flags`; `IVSBGHUDsState.change_symbols_visibility` — **beside the widget layer, a marked exception** |
| Show / hide GUI | `ui_widgets/hide_gui_button.gd`, `show_gui_button.gd` | `IVShowHideUI.show_hide_gui` |
| User settings | `ui/options_popup.gd` (`IVOptionsPopup`) | `IVSettingsManager.change_setting`; `cache_now` on Confirm |
| Save / load (Save plugin) | `gui/quicksave_button.gd`, `quickload_button.gd`, `save_dialog.gd`, `load_dialog.gd` | `IVSave.quicksave`, `quickload`, `save_file`, `load_file` |

A class that adds a write-side member should add a row here and declare it at the widget level.

## 11. Automation: classes declare their own interaction

Any class — a Core singleton or program object, a tree node, a widget, or a project's own — declares what a client may read and call. The Assistant reads the declarations through Godot alone; nothing in a declaring class refers to the Assistant. This is the `PERSIST_*` pattern of the Save plugin: the class declares, a scanner reads. Core's declarations are the templates a project follows.

### 11.1 Declarations

Constants are prefixed `AUTOMATION_`; methods carry `automation` after Godot's verb. All are optional.

- `const AUTOMATION_METHODS: Array[StringName]` — methods a client may call.
- `const AUTOMATION_PROPERTIES: Array[StringName]` — properties a client may read: `var`s, getters, Godot-native properties (`global_position`, `visible`) or constants (`IVUnits.KM`). Writes go through methods.
- `const AUTOMATION_KEY: Array[StringName]` — for a class with several instances, the properties that tell one from another (`IVBody`: `name`; `IVNavButton`: `body_name`; `IVHUDsCheckBox`: `hud_type`, `body_flags`, `sbg_aliases`). A class with one instance needs none. Key properties are readable whether or not they are also in `AUTOMATION_PROPERTIES`.
- `func is_automation_available(member: StringName) -> bool` — the class's own gates: whether a client may use `member` now. A member the class says is unavailable is listed under `unavailable` in `describe` and refused with code 5. Without this method every declared member is available.
- `func get_automation_objects() -> Dictionary[StringName, Object]` — further objects, by role name. `IVGlobal` returns its `program` dictionary, so program objects are found under a role (`"SpeedManager"`) that survives a project substituting its own class; `IVTopUI` returns its selection manager as `"SelectionManager"`.
- `const AUTOMATION_LIFECYCLE: Dictionary[StringName, StringName]` — on one autoload, the project's lifecycle (§11.6).
- Widgets only: `get_automation_value()`, `set_automation_value(value)` and `get_automation_options()` (§11.7).

A subclass can't redeclare a parent's constant, so, as with `PERSIST_PROPERTIES2`, it adds `AUTOMATION_METHODS2`, `AUTOMATION_PROPERTIES2` (any numeric suffix); the Assistant unions every level. A subclass may withdraw an inherited member by overriding `is_automation_available()`.

```gdscript
# timekeeper.gd
const AUTOMATION_METHODS: Array[StringName] = [
	&"set_time",
	&"set_time_from_date_clock_elements",
	...
]
const AUTOMATION_PROPERTIES: Array[StringName] = [&"time", &"julian_day_number", ...]

## Whether an automation client may use [param member] now: setting time needs
## [member IVCoreSettings.allow_time_setting] and is never done by a network client.
func is_automation_available(member: StringName) -> bool:
	const IS_CLIENT = IVStateManager.NetworkState.IS_CLIENT
	match member:
		&"set_time", &"set_time_from_date_clock_elements", ...:
			return IVCoreSettings.allow_time_setting and _network_state != IS_CLIENT
	return true
```

Declared members are public API. Renaming or removing one breaks client scripts, never the Assistant, and is `[API breaking]` in the declaring repository's changelog.

### 11.2 Objects

The Assistant finds objects when a request arrives, so objects freed on a reset simply drop out:

1. Each autoload (by its autoload name) whose script declares anything.
2. The objects each found object names in `get_automation_objects()`, by role, breadth first.
3. Every node in the scene tree whose script declares anything.

An object's class is its script's most-derived `class_name`; an autoload's script without one is named by its autoload name (`IVStateManager`, `IVGlobal`).

### 11.3 Addresses

An address names one object:

- A name: an autoload, a role, or a class with exactly one instance (`"Timekeeper"`, `"IVStateManager"`, `"IVCamera"`). A node path starting with `/` also works for a declaring node.
- `{"class": ..., <key>: ...}` — an instance of a keyed class by any of its key properties (`{"class": "IVBody", "name": "PLANET_MARS"}`). Key values compare as JSON, so an enum key takes its name (`"hud_type": "ORBITS"`). An address that matches several instances is an error listing them.
- `{"path": ...}` or `{"name": ...}` — a node path or a name, as above.
- `"via"` (string or array) on any of these — declared properties to follow to the object they hold: `{"class": "IVBody", "name": "PLANET_MARS", "via": "orbit"}` is Mars's `IVOrbit`, which declares its own members.

A parameter typed with a class takes an address, or, for a class with a one-property key, just that value: `IVCameraHandler.move_to` takes `"to_node3d": "PLANET_EARTH"`.

### 11.4 Values in JSON

Arguments convert to each parameter's declared type, and results and properties convert back, by Godot's own type information:

| Godot | JSON |
|---|---|
| `bool`, `int`, `float`, `String`, `StringName`, `NodePath` | as is; a non-finite float is `"inf"`, `"-inf"` or `"nan"` |
| enum | its value's name (`"REFERENCE_PLANE_ECLIPTIC"`); an argument also takes the integer, or an array of names OR'd as flags |
| `int` that holds flags | the integer; an argument also takes a name, or an array of names, from the declaring class's enums (`"body_flags": ["BODYFLAGS_PLANET"]`) |
| `Vector2/3/4(i)`, `Quaternion`, `Plane`, `Rect2(i)`, `AABB` | arrays of numbers |
| `Basis` | three column arrays; `Transform3D`: `{"basis": ..., "origin": ...}` |
| `Color` | `"#rrggbb"` (`"#rrggbbaa"` when translucent); an argument also takes `[r, g, b, a]` |
| `Array[T]`, `Dictionary[K, V]`, packed arrays | arrays and objects of converted elements; typed containers are rebuilt typed |
| object with `AUTOMATION_KEY` | its address, `{"class": ..., <key>: ...}` |
| other declaring object | its role or autoload name if it has one, else its declared properties as an object with `"class"` (a value, like an `IVOrbit` or `IVView`) |
| any other object | `{"class": ..., "path": ...}` |
| `Variant` argument | as is; a whole number becomes an `int` (JSON has no integers) |

A type with no JSON form above may be given as Godot prints it (`"Basis(...)"`).

### 11.5 Descriptions: the doc comments

A declared member's `##` doc comment is its description, and a class's is its own: one copy, written from a caller's point of view, so doc-comment quality is part of what a client depends on. No runtime API exposes doc comments (Godot 4.7), so the Assistant parses them from source, as plain text with BBCode reduced to Markdown code spans.

An export ships scripts as binary tokens, without comments. `IVAssistantExportPlugin` therefore parses every script that declares automation members, and the scripts they extend, when an export begins, and adds the result to the export as `res://addons/ivoyager_assistant/automation_docs.json`. At runtime the Assistant reads a script's source where it has one and the digest otherwise. An export in which the server can't run (§7.3) gets no digest.

### 11.6 Lifecycle

The server's last project knowledge is when to listen and when to stop. One autoload declares it:

```gdscript
# state_manager.gd (IVStateManager)
const AUTOMATION_LIFECYCLE: Dictionary[StringName, StringName] = {
	&"initialized": &"core_initialized",
	&"started": &"simulator_started",
	&"stopping": &"about_to_free_procedural_nodes",
	&"quitting": &"about_to_quit",
	&"quit": &"quit",
}
```

`initialized`, `started`, `stopping` and `quitting` name signals (§2.3); `quit` names the method the server's `quit` calls with `force`. The server reads the first autoload that declares it. Any role may be absent: without `initialized` the server listens at once, without the declaration it also counts as started at once.

### 11.7 Widgets

A widget follows the same convention, and the Assistant adds what it knows of Godot's `Control` families.

**Meaning: Godot's accessibility properties.** A widget says what it is with `accessibility_name` and `accessibility_description`, names its label with `accessibility_labeled_by_nodes` (a HUDs row's checkboxes, labeled by the row) and names what it opens with `accessibility_controls_nodes` (an `IVPanelButton` and its panel; a popup button and its popup). AccessKit hands the same properties to a screen reader, so no widget carries a second, AI-only description. Godot translates `accessibility_name` when read, so a widget sets a translation key. The Assistant names a widget by its label and its own name, falling back to its text, and to its tooltip where the text is a symbol (`"||"`, `"+"`).

**Identity: a key, not a path.** Paths break when a GUI is rearranged, widgets built at runtime have generated names, and displayed text is translated, so a widget with several instances declares `AUTOMATION_KEY`. A widget class with one instance is addressed by its class, and a control with no script by its node path.

**Operation: per-family defaults.** Each family is operated the way that fires everything a user's operation fires, which a property setter often does not. Measured in Godot 4.7.2:

| Family | Operation | Why |
|---|---|---|
| `BaseButton` (`Button`, `CheckBox`, `CheckButton`; toggle or not, grouped or not) | Focus it, deliver `ui_accept` to its viewport (the keyboard user's path), restore focus | No script call fires everything a click does. The `button_pressed` setter fires `toggled` and `_toggled()` but not `pressed` or `_pressed()`; emitting `pressed` skips `_pressed()` and the toggle. |
| `Range` (`Slider`, `SpinBox`, ...) | Set `value` | Fires `value_changed`. |
| `TabContainer` | Set `current_tab` | Fires `tab_selected` and `tab_changed`. |
| `FoldableContainer` | `fold()` / `expand()` | The `folded` setter fires nothing. |
| `OptionButton` | `select()`, then emit `item_selected` | Neither `select()` nor the `selected` setter fires it. |
| `LineEdit` | Set `text`, emit `text_changed`; emit `text_submitted` on request | The setter fires nothing. |
| `TextEdit` | Set `text`, emit `text_changed` | The setter fires only `text_set`. |

Delivered through a viewport, `ui_accept` meets `_input()` handlers before the focused button, and one that consumes it would swallow the press. A widget whose handling no default reproduces declares the value interface below instead. A control that neither the mouse nor the keyboard reaches (`MOUSE_FILTER_IGNORE` and `FOCUS_NONE`, e.g. a layout spacer) is not a widget.

**Composite widgets: their own value interface.** A widget whose state is not one control's declares `get_automation_value()` and `set_automation_value(value)`, plus `get_automation_options()` where the value is one of a set. `set_automation_value()` calls the Core method the widget's own handlers call, and returns `false` to refuse a value. The Assistant treats such a widget as one unit: the controls of its own scene (those it owns) are not widgets, though controls a project adds to it are. In Core: `IVSpeedButtons` (a speed index), `IVTrackCkbxs` (`"ecliptic"`, `"orbit"`, `"ground"`), `IVTimeSetter` (`[year, month, day, hour, minute, second]`) and `IVFocalLengthControl` (millimeters). A container without the interface (`IVHUDsBox`) is descended.

**Reach.** Popups are in-tree `Window`s, and a widget meant for automation exists in the tree, hidden if need be, so its absence from `list_widgets` means the project lacks it. A hidden widget is reached by operating its opener first, which `list_widgets` names as `opened_by`; no project configures scene roots.

**Guards:**
- A disabled, non-editable or hidden widget is refused with an error, never a silent no-op. A hidden one's error names the widget that shows it.
- Nothing is clicked at a screen position: nothing is hit-tested, so overlapping controls, GUI scale and headless runs don't matter.
- The result echoes the widget's state after the operation, so a client can confirm without a follow-up read.

### 11.8 Writing declarations

- Declare the entry point a GUI widget calls (§10); a member below it is a marked exception whose doc comment says so.
- The doc comment is the description a client reads: say what the member does and when it does nothing, in a caller's terms.
- Gate in `is_automation_available()` what would otherwise silently do nothing (`IVSelectionManager.select_up` with nothing above, `IVStateManager.start` once started, setting time where it isn't allowed); a method that can't tell from its arguments alone returns whether it acted (`IVSelectionManager.select_by_name`, `IVTimekeeper.set_time_from_date_clock_elements`).
- A value a client reads but never addresses (an orbit's elements, a view's state) needs only `AUTOMATION_PROPERTIES`; it is read through the object that holds it.
- A project declares the same way: `planetarium/units.gd` declares the unit constants a client converts by, and a project's replacement for a Core class declares its own members.
