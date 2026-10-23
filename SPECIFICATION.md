# I, Voyager Assistant — Specification

## 1. Purpose

The Assistant plugin provides a programmatic interface to an I, Voyager project, or any Godot project (§8), with two goals:

1. **AI-assisted testing** — Enable AI tools (Claude Code) to query simulation state and exercise controls, verifying correctness of orbital mechanics, scene tree construction, time management, and GUI behavior.
2. **AI assistant** — A user talks, by text or voice, with an AI of their choosing, which operates the app on their behalf. It works in any build, the web included: inside the app, through a model the user connects or the project ships beside it, or from the user's own AI application alongside. It is how voice and natural language reach the app, so it serves accessibility first; screen readers, announcements and spatial audio need no AI and belong to the GUI itself (in I, Voyager, Core's widgets), not here.

Both goals use one interface, what a project's classes declare (§11). They differ in the client: a developer's tool outside a debug build, or the user's assistant inside a shipped one.

Goal 2 divides the work three ways:

- **The model** is never part of the plugin. It is a remote service, a local server the user runs, or a server the project ships beside the app.
- **The plugin** provides the plumbing: connections to models and a setup wizard, the conversation loop that runs the model's tool calls through the declarations, and a chat box.
- **The project** provides the assistant's personality, the tools it offers, which connections to offer, and the chat box's style and place. The Planetarium puts it in a panel at the bottom center.

Goal 2 is under way (`CODING_PLAN.md` Phase 5): `IVAssistant` reaches the app in process in any build (§2.1), and connections to models, the conversation loop and the chat box are still to come.

The plugin knows Godot, not the project. A project's classes declare what a client may read and call (§11), and the Assistant discovers and dispatches those declarations; so a change in Core or in a project needs no change here.

## 2. Architecture

### 2.1 Integration with a project

- **EditorPlugin** — Registers the `IVAssistantServer` and `IVAssistant` autoloads via `add_autoload_singleton()` when the plugin is enabled, and removes them when disabled. It also registers `IVAssistantExportPlugin`, which adds declared members' doc comments to an export (§11.5).
- **IVAssistantServer** — The test client's transport (goal 1). An autoload Node (root-level singleton). Reads config in `_ready()`, finds the project's lifecycle declaration (§11.6), and on its "initialized" signal starts a TCP server. Processes commands in `_process()` on the main thread. Runs only in debug builds unless configured otherwise, and is inert in a web export, which has no `TCPServer`. It refers to no project class.
- **IVAssistant** — The user's assistant (goal 2). An autoload Node, inert unless the project enables it (§7.3). Its `request(method, params)` answers a request in process, as the server answers a client's, so it runs in any build, release and web included, with no network listener. It reaches only the user's surface: the members classes mark as the user's (§11.1), the widgets (§4.3) and the input actions (`list_actions`, `press_action`).
- **IVAssistantDispatcher** — Answers one request by its method: `describe`, `get`, `call` and the built-in tools. The server and `IVAssistant` each hold one, so a model's tool call takes the path a test client's request does.
- **IVAssistantAutomation** — Discovers the objects that declare automation members and serves `describe`, `get` and `call` (§4.1, §4.2, §11).
- **Built-in tools** — `IVAssistantWidgets` (list and operate widgets, §4.3) and `IVAssistantGodotTools` (screenshots, mouse, input actions, GUI inspection, §4.4–4.6). Both need only Godot.

### 2.2 Component Diagram

```
EditorPlugin (editor/editor_plugin.gd)
  ├─ _enter_tree(): reads ivoyager_assistant.cfg, calls add_autoload_singleton()
  └─ IVAssistantExportPlugin: adds the doc-comment digest to exports (§11.5)

IVAssistantServer (autoload Node, root-level singleton; the test client's)
  ├─ _ready(): reads config and command-line args, checks enabled/debug_only
  ├─ finds AUTOMATION_LIFECYCLE on an autoload and connects its signals (§11.6)
  ├─ on lifecycle "initialized": starts TCPServer on 127.0.0.1:<port> (§7.3)
  ├─ on lifecycle "started": begins evaluating the readiness gate (§7.4)
  └─ _process(): polls TCP, reads JSON requests (or batches), dispatches, writes responses
       ├─ server: get_project_info, quit
       └─ IVAssistantDispatcher: everything else

IVAssistant (autoload Node; the user's assistant, inert unless enabled)
  └─ request(method, params): answers in process
       └─ IVAssistantDispatcher: everything

IVAssistantDispatcher (one per client)
  ├─ describe, get, call
  ├─ IVAssistantAutomation: discovery, addresses, conversion, availability (§11)
  └─ built-in: IVAssistantWidgets (§4.3), IVAssistantGodotTools (§4.4–4.6)
```

### 2.3 Lifecycle

This is the server's lifecycle. `IVAssistant` has none: once enabled, it answers on whatever exists, and a declared member's class says what is available now (§11.1).

1. EditorPlugin registers `IVAssistantServer` as an autoload when the plugin is enabled.
2. On game start, `IVAssistantServer._ready()` reads config and command-line overrides (§7.3) and checks `enabled`/`debug_only`. Once every autoload is in the tree, it finds the first autoload whose script declares `AUTOMATION_LIFECYCLE` (§11.6; in Core, `IVStateManager`) and connects to the signals it names.
3. On "initialized" (Core: `core_initialized`): the TCP server starts listening. Every method works from here on, on whatever exists and is available.
4. On "started" (Core: `simulator_started`): the readiness gate begins evaluating each frame.
5. **Readiness gate opens** after the project-supplied `ready_predicate` (default trivially true) has returned `true` for `min_ready_delay_frames` consecutive frames (default 10). `get_project_info` reports it as `ready`. See §7.3 and §7.4.
6. On "stopping" (Core: `about_to_free_procedural_nodes`): the readiness gate re-arms. Declared objects freed now simply drop out of `describe`.
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
- Port configurable via `ivoyager_assistant.cfg` under `[assistant_server]` section, or per process on the command line (§7.3), so several instances can run on one machine

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
| 4 | Retired in protocol 5 (was: a suite method before the readiness gate opened) |
| 5 | Not allowed (a declared member that isn't available now, or a widget that is disabled, hidden or refuses the value) |

## 4. API Methods

### 4.0 Project Info and Quit

#### `get_project_info`
Returns project identity, the server's lifecycle state, its methods and optional context. Available as soon as the TCP server starts.

**Params:** none

**Result:**
```json
{
  "assistant_protocol_version": 5,
  "project_name": "I, Voyager - Planetarium",
  "project_version": "0.2.3.dev",
  "assistant_name": "I, Voyager - Planetarium",
  "started": true,
  "ready": true,
  "capabilities": ["call", "describe", "find_nodes", "get", "get_mouse_position", "..."],
  "process_id": 12345,
  "port": 29071,
  "instance_id": "run-a"
}
```

- `started` — the lifecycle "started" signal has fired (§2.3); `ready` — the readiness gate is open (§7.4).
- `capabilities` — every method the server answers: its own and the built-in tools'. What a project's classes offer is in `describe`, not here.
- `assistant_name` defaults to `project_name` unless overridden in config. `context` (string, optional) is included if a context file is configured.
- `process_id` (int) is the game's OS process id — on Windows the game's own process, not the `_console.exe` wrapper a launcher starts — and `port` the port it listens on.
- `instance_id` (string, optional) echoes the `--assistant-instance` command-line argument (§7.3). A launcher that passes one can confirm it reached the process it started rather than another instance holding the port.

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

A client's whole context in one call: every declared object and class, with each member's signature and description, which members are the user's, the enum values members use, which members are unavailable now, and the widgets a user can see and the input actions. All of it is generated from the running app, so anything absent is something the project does not offer, or does not offer now.

**Params:**
- `full` (bool, optional, default `false`) — Full class descriptions, rather than each class's first paragraph.
- `instances` (bool, optional, default `true`) — List each instance of a keyed class.
- `widgets` (bool, optional, default `true`) — Include the visible widgets (as `list_widgets` with `visible_only`).
- `actions` (bool, optional, default `true`) — Include the input actions (as `list_actions`).
- `user` (bool, optional, default `false`) — Only the user's surface: the members marked as the user's (§11.1), on the objects and classes that have any. It is what the user's assistant is given, which can't ask for more.

**Result (abbreviated):**
```json
{
  "objects": {
    "Timekeeper": {
      "class": "IVTimekeeper",
      "description": "Maintains simulator \"time\" (TT; J2000 epoch), Julian Day Number, ...",
      "methods": {
        "set_time": {"description": "Sets `time` and emits `time_set`. ...",
            "args": [{"name": "new_time", "type": "float"}], "returns": "void"}
      },
      "properties": {"time": {"type": "float", "description": "Terrestrial Time (TT) ...",
          "user": true}}
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
- `user` is `true` on a member a class marks as the user's (§11.1): what a user's assistant (§1) may use. The rest is the test surface, which reaches state however the GUI looks.
- `unavailable` — declared members the class says can't be used now (§11.1). For a keyed class, per instance.
- `enums` — each enum a member's type names, and each enum constant of a declaring class, by name.

### 4.3 Widgets

The user surface: the `Control`s a user operates, operated the way a user operates them so each widget's own handler runs. See §11.7 for how a widget names, identifies and describes itself.

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

To capture without the GUI, compose it: `IVShowHideUI.show_hide_gui(false, false)`, `screenshot` with `redraw`, `IVShowHideUI.show_hide_gui(false, true)`, in one batch. `IVBodyHUDsState.set_huds_hidden(true)` hides the 3D HUDs (orbit lines, names, symbols, small-body points) the same way; read `huds_hidden` back rather than assume it.

### 4.5 Mouse, Input Actions and Projection

Every position these take or return is in **window pixels**: the pixels of a `screenshot` image. On a hi-DPI screen a project's display scale makes them finer than the GUI's logical pixels (2.5 to one at 250% Windows scaling), and the methods convert between the two so a client never has to.

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

`on_screen` is `true` only when `behind_camera` is `false` and the pixel is inside the viewport rect.

**Hover identification.** What the user sees under the mouse is `IVMouseTargetLabel`'s declared `text` and `visible` (§4.1), whatever identifies it — tests written against the label stay valid when the identifier underneath is replaced. A workflow: frame the target (`IVViewManager.set_table_view`, or `IVCameraHandler.move_to_by_name`); make its HUD visible (an orbit line, `IVBodyHUDsState.set_all_orbits_visibility`; an asteroid's points, `IVSBGHUDsState.change_symbols_visibility`); hide the GUI, since a panel over the pixel takes the mouse from the world; project; `warp_mouse`; wait ~250–400 ms (the fragment identifier runs an 8-frame cycle); read `IVMouseTargetLabel.text`; restore what you changed. `tools/assistant_test.py` does all three: a body, an orbit line, an asteroid point.

#### `list_actions`
The project's input actions, the user's keyboard surface, with the events bound to each. Godot's own `ui_*` actions are left out.

**Params:** `include_ui` (bool, optional, default `false`)

**Result:** `{"actions": {"toggle_pause": ["Space"], "incr_speed": ["Period"], "...": []}}`

A project may declare display names (Core: `IVInputMapManager.action_texts`).

#### `press_action`
Emulates a user hotkey press. Injects the action's `InputEventKey` into Godot's input pipeline via `Input.parse_input_event()`, so it flows through `_shortcut_input()` handlers exactly like a physical key press. Both press and release events are injected.

**Params:** `action` (string, required) — An action from `list_actions` (e.g. `"toggle_pause"`).

**Result:** `{"ok": true, "action": "toggle_pause"}`

Note: camera movement actions (e.g. `camera_up`) are designed for sustained key holds; an instant press and release has negligible effect. `toggle_all_huds` is a toggle, so what it leaves on screen depends on whether the HUDs were already hidden; `IVBodyHUDsState.set_huds_hidden` is deterministic.

### 4.6 GUI Inspection

Generic scene tree inspection methods that work on any GUI node without per-widget custom code. Available before the simulator starts. For what a user can operate, `list_widgets` (§4.3) is the better start; these read what is displayed.

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

### 4.7 Removed suite methods

Protocol 5 removed the suites that bound to Core classes, which predated §11, and with them the methods below. Core's classes declare the same state and controls; a client uses `describe`, `get`, `call` and the widgets, and this table is the migration.

| Removed method | Instead |
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

`screenshot`, `project_to_screen`, `list_actions`, `press_action`, `warp_mouse` and the GUI inspection methods were in these suites too, and remain, built in (§4.4–4.6).

## 5. Dependencies

The server, `IVAssistantAutomation` and the built-in tools depend on Godot alone. They find the project's objects through the convention of §11 and never name a project class; the last Core knowledge, the lifecycle signals, is read from `IVStateManager`'s own `AUTOMATION_LIFECYCLE` declaration (§11.6).

## 6. Threading and Safety

- All TCP I/O and command processing runs on the main thread in `_process()`
- This is safe for scene tree access but limits throughput to frame rate (~60 Hz)
- For testing, and for an assistant whose model answers in seconds, a frame's latency is adequate
- The server processes all pending complete messages each frame (not just one); a batch runs within one frame
- A declared method runs on the main thread as any GUI handler does; a class whose members are not main-thread safe gates them in `is_automation_available()` or doesn't declare them

## 7. Configuration

`ivoyager_assistant.cfg` (abbreviated):

```ini
[assistant_autoload]
IVAssistantServer="../assistant_server.gd"
IVAssistant="../assistant/assistant.gd"

[assistant_server]
enabled=true
debug_only=true
port=29071
min_ready_delay_frames=10

[assistant]
enabled=false
assistant_name=""
context_file=""
```

### 7.1 Autoload Registration

The `[assistant_autoload]` section declares autoloads managed by the EditorPlugin. When the plugin is enabled in Godot's Plugin manager, `IVAssistantServer` and `IVAssistant` are registered as autoloads. Projects can negate either by setting it to `""` in `ivoyager_override.cfg`.

### 7.2 Project helpers

A project's own probes and test helpers are classes like any other: each declares its automation members (§11.1) on an object the Assistant finds (§11.2) — an autoload, a node in the tree, or an object a declaring object names in `get_automation_objects()` — and a client calls them with `call`. In Core, a project adds one to the program in an override config, where `IVGlobal` names it by its key:

```ini
[core_initializer]
program_refcounteds/MyProbe="res://tests/my_probe.gd"
```

A member that needs frames to finish (a render, a capture) starts the work and returns, and a second member returns the result once it lands. A member given something it can't act on returns `{"_error": {"code": ..., "message": ...}}`, which the server sends as an error response (§3.3). The `[assistant_test_suites]` section and `IVAssistantTestSuite` were removed in protocol 5.

### 7.3 Runtime Settings

The `[assistant_server]` section controls the TCP server:

- `enabled` — Master enable/disable (default: true). When false, the autoload node exists but does not start the TCP server.
- `debug_only` — If true, server only starts when `OS.is_debug_build()` is true (default: true).
- `port` — TCP listen port (default: 29071)
- `min_ready_delay_frames` — Number of consecutive frames the project's `ready_predicate` must return `true` (after the lifecycle "started" signal) before the readiness gate opens (default: 10). Allows projects with deferred main-thread work after start (e.g. cross-thread initialization arriving via `call_deferred`) to settle before save/load and similar operations are permitted. See §7.4.

The `[assistant]` section configures the user's assistant, and the identity both clients are given:

- `enabled` — Whether the project offers the user's assistant, `IVAssistant` (default: false). When true it runs in every build, release and web included.
- `assistant_name` — Display name for the assistant persona (default: empty, uses project name from ProjectSettings)
- `context_file` — Path to a text file (`res://` relative) with project-specific context for AI clients (default: empty)

The export digest of doc comments (§11.5) is added to an export in which the user's assistant is enabled or the server can run, and to no other.

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

`get_project_info` reports the gate as `ready`, and a project reads it with `IVAssistantServer.is_ready()`. It gates nothing itself: a declared member's class owns its gates (§11.1).

## 8. Cross-Project Compatibility

The plugin is designed as a git submodule usable across any I, Voyager project, and any Godot project that declares automation members. Enable the plugin in Project Settings → Plugins — no project-level config changes are needed.

### 8.1 Feature Availability

What a project offers is what its classes declare and say is available now, and `describe` (§4.2) reports exactly that: a missing object or member is one the project lacks; a member under `unavailable` exists but can't be used now (a network client's time setting, a selection step with nowhere to go, `IVStateManager.start` once started). Calling either is an error (codes 3, 1 and 5), never a silent no-op. Every Core program object a project replaces keeps its role name (`"SpeedManager"`), and a replacement class declares its own members (§11.1).

`get_project_info`'s `capabilities` lists the server's own methods and the built-in tools' only.

The protocol version is reported as `assistant_protocol_version`: `5` removed the suites and their methods (§4.7), and `get_project_info`'s `methods` and `gated_out`; `4` added `describe`, `get`, `call`, the widget methods, batches, `ready`, and the lifecycle declaration; `3` added `process_id`, `port` and `instance_id`.

### 8.2 Splash Screen Handling

Projects with `IVCoreSettings.wait_for_start = true` display a splash screen before starting the simulation. The TCP server starts on the lifecycle "initialized" signal, before the splash screen, so a client can:

1. Connect and call `get_project_info` and `describe` to discover the project
2. `get` `IVStateManager` (`ok_to_start`, `started`) and `IVCoreSettings.wait_for_start`
3. `call` `IVStateManager.start` once it is available, to start the simulation (bypassing the splash screen), then poll `get_project_info` until `ready`

### 8.3 Project Identity

Projects can customize the assistant's identity via config, under `[assistant]`:
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
5. **Save/load cycle** (if the project declares the Save plugin's `IVSave`): `call` `IVSave.quicksave`, then poll `get` `IVSave.is_saving` until it is `false`. `call` `IVSave.quickload`, then poll until `IVSave.is_loading` is `false` and `IVStateManager.started` is `true`.
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

- **Readiness:** `ready` in `get_project_info` says the readiness gate is open. Declared members answer whatever exists, so before the start a body simply isn't found yet.
- **Unavailable is not missing:** code 5 means the member exists but its class says it can't be used now; code 1, that the class doesn't declare it.
- **Async save/load:** `IVSave.quicksave` and `quickload` answer before they finish. Poll `IVSave.is_saving` and `is_loading` for completion. During load, objects freed and rebuilt drop out of `describe` until the new ones exist.
- **Per-frame processing:** Requests are processed once per frame (~60 Hz). A batch runs within one frame, so its calls see each other's effects but no frame renders between them; pass `redraw` to a `screenshot` that follows a change in the same batch.
- **Persisted state:** HUD visibility and views persist across sessions, and a project may restore them at startup, so a test sets the state it depends on explicitly and restores what it changed. `IVSettingsManager.change_setting` writes the settings file unless `suppress_caching` is `true`.

## 10. Core surface classes (layering principle)

A class declares, for an automated action, **the same entry point its GUI widget calls, at the same abstraction level.** When a control exists in the GUI, the declared method is the one the widget's handler calls — not a lower-level primitive. This keeps an automated action and a user's button click semantically identical and on the same code path, which serves both goals in §1: faithful testing, and an assistant whose actions are the user's own. (Operating the widget itself, §4.3, is the same path by construction.)

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

**The user's members.** A user's assistant may call a widget-level entry point, and read what a user sees (the selection, the date, a body's radius, a view's state), so a class marks those as the user's in `AUTOMATION_USER_METHODS` and `AUTOMATION_USER_PROPERTIES` (§11.1). A marked exception never is, nor is a test probe, nor a raw internal a widget doesn't show (`IVCamera.view_position`, `IVStateManager.building_system`). A write method no widget calls, such as `IVTimekeeper.set_time`, stays the test client's, as do the bulk HUD setters above.

## 11. Automation: classes declare their own interaction

Any class — a Core singleton or program object, a tree node, a widget, or a project's own — declares what a client may read and call. The Assistant reads the declarations through Godot alone; nothing in a declaring class refers to the Assistant. This is the `PERSIST_*` pattern of the Save plugin: the class declares, a scanner reads. Core's declarations are the templates a project follows.

### 11.1 Declarations

Constants are prefixed `AUTOMATION_`; methods carry `automation` after Godot's verb. All are optional.

- `const AUTOMATION_METHODS: Array[StringName]` — methods a client may call.
- `const AUTOMATION_PROPERTIES: Array[StringName]` — properties a client may read: `var`s, getters, Godot-native properties (`global_position`, `visible`) or constants (`IVUnits.KM`). Writes go through methods.
- `const AUTOMATION_USER_METHODS: Array[StringName]`, `const AUTOMATION_USER_PROPERTIES: Array[StringName]` — methods and properties that are also the user's: a user's assistant may use them, and no others (§10). They are declared members like the rest, so a member is listed once, here or in the lists above. Marking is opt-in, so a member a class forgets to mark is kept from the user's assistant, never exposed to it.
- `const AUTOMATION_KEY: Array[StringName]` — for a class with several instances, the properties that tell one from another (`IVBody`: `name`; `IVNavButton`: `body_name`; `IVHUDsCheckBox`: `hud_type`, `body_flags`, `sbg_aliases`). A class with one instance needs none. Key properties are readable whether or not they are also in `AUTOMATION_PROPERTIES`.
- `func is_automation_available(member: StringName) -> bool` — the class's own gates: whether a client may use `member` now. A member the class says is unavailable is listed under `unavailable` in `describe` and refused with code 5. Without this method every declared member is available.
- `func get_automation_objects() -> Dictionary[StringName, Object]` — further objects, by role name. `IVGlobal` returns its `program` dictionary, so program objects are found under a role (`"SpeedManager"`) that survives a project substituting its own class; `IVTopUI` returns its selection manager as `"SelectionManager"`.
- `const AUTOMATION_LIFECYCLE: Dictionary[StringName, StringName]` — on one autoload, the project's lifecycle (§11.6).
- Widgets only: `get_automation_value()`, `set_automation_value(value)` and `get_automation_options()` (§11.7).

A subclass can't redeclare a parent's constant, so, as with `PERSIST_PROPERTIES2`, it adds `AUTOMATION_METHODS2`, `AUTOMATION_USER_PROPERTIES2` and so on (any numeric suffix); the Assistant unions every level. A subclass may withdraw an inherited member by overriding `is_automation_available()`.

```gdscript
# timekeeper.gd
const AUTOMATION_USER_METHODS: Array[StringName] = [
	&"set_time_from_date_clock_elements", # the time setter widget's entry point
	&"set_operating_system_time_sync",
	...
]
const AUTOMATION_USER_PROPERTIES: Array[StringName] = [&"time", &"julian_day_number", ...]
const AUTOMATION_METHODS: Array[StringName] = [&"set_time", &"synchronize_with_operating_system"]
const AUTOMATION_PROPERTIES: Array[StringName] = [&"clock_time"]

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

The Assistant finds objects when a request arrives and lets them go once it is answered, so it keeps none alive between requests and objects freed on a reset simply drop out:

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

An export ships scripts as binary tokens, without comments. `IVAssistantExportPlugin` therefore parses every script that declares automation members, and the scripts they extend, when an export begins, and adds the result to the export as `res://addons/ivoyager_assistant/automation_docs.json`. At runtime the Assistant reads a script's source where it has one and the digest otherwise. An export gets the digest where the user's assistant is enabled or the server can run (§7.3), and no other does.

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
- Mark as the user's the widget-level entry points and what a user sees (§10), and nothing else: a remote model may drive a user's assistant, so what it may do is no more than what the user's own GUI does.
- The doc comment is the description a client reads: say what the member does and when it does nothing, in a caller's terms.
- Gate in `is_automation_available()` what would otherwise silently do nothing (`IVSelectionManager.select_up` with nothing above, `IVStateManager.start` once started, setting time where it isn't allowed); a method that can't tell from its arguments alone returns whether it acted (`IVSelectionManager.select_by_name`, `IVTimekeeper.set_time_from_date_clock_elements`).
- A value a client reads but never addresses (an orbit's elements, a view's state) needs only properties; it is read through the object that holds it.
- A project declares the same way: `planetarium/units.gd` declares the unit constants a client converts by, and a project's replacement for a Core class declares its own members.
