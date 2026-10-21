# Changelog

This file documents changes to [ivoyager_assistant](https://github.com/ivoyager/ivoyager_assistant).

File format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).


## [v0.0.5] - UNRELEASED

Under development using Godot 4.7.2.

### Added
* Automation: a class declares what a client may read and call (`AUTOMATION_*` constants, `is_automation_available()`, `get_automation_objects()`), and new methods `describe`, `get` and `call` discover and use those declarations through Godot alone, converting JSON by the declared types. See SPECIFICATION.md §11 and §4.1–4.2.
* Methods `list_widgets` and `operate_widget`, which list a user's controls by their accessibility names and keys and operate them as a user does, a composite widget through its declared value interface. See SPECIFICATION.md §4.3 and §11.7.
* JSON-RPC 2.0 batch requests, answered in order within one frame.
* `IVAssistantExportPlugin`, which adds declared members' doc comments to an export for `describe` to report.
* Built-in method `get_mouse_position`; `screenshot` takes `redraw`, and `project_to_screen` a `node` address with an `offset`.
* `AssistantClient` in `tools/assistant_test.py` has `describe()`, `get()`, `invoke()` and `batch()`, raising `AssistantError` on an error response.
* New SettingsSuite with `get_options` and `set_option`, which read and change user settings as the Options popup does, naming a dropdown setting's values; a change is not written to the settings file unless `persist` is given. See SPECIFICATION.md §4.11.
* Methods `get_huds`, which reads every HUD's visibility by body class and small-body group, and `set_class_huds`, which sets one HUD for chosen classes or groups as the GUI's HUD checkboxes do, in the control suite.

### Changed
* The server takes its lifecycle signals and quit from an autoload's `AUTOMATION_LIFECYCLE` declaration and refers to no Core class; `get_project_info` reports protocol version 4 and `ready`. `get_state`, `start_game` and the Core fields of `get_project_info` moved to `CoreTestSuite`, and the requirement tokens to `IVAssistantRequirementTokens`.
* `press_action`, `warp_mouse`, `list_actions`, `project_to_screen`, `screenshot` and the GUI inspection methods (formerly `GuiInspectionSuite`) are built in, needing only Godot. A deprecated suite that keeps its own parameters for one of them (`screenshot`'s `hide_gui`, `project_to_screen`'s `body`) hands the rest to the built-in.
* `tools/assistant_test.py` tests through declared members, batches and widgets; save/load keeps the deprecated methods.
* [API breaking] `set_huds` hides and shows the HUDs as the GUI's hide-HUDs button does (`IVBodyHUDsState.set_huds_hidden`), so `{"visible": true}` restores what was on screen rather than each system's defaults, hidden HUDs no longer carry into the user's next session, and the result adds `huds_hidden`. To set HUD visibility to a known state, apply a view that sets it.
* `GodotLauncher` in `tools/assistant_test.py` holds each launched Godot to one logical processor of each core on Windows, which can otherwise put the busy threads of instances run at once two to a core; `one_per_core=False` leaves it unpinned. See SPECIFICATION.md §7.3.
* SPECIFICATION.md, CODING_PLAN.md and README.md are brought up to date with the code: methods they omitted (`set_camera_fov`, the cached-view, HUD-visibility and small-body methods) are documented, and stale suite names, result fields and §10's list of layering exceptions are corrected.

### Deprecated
* The default suites that bind to Core (`StateQuerySuite`, `ControlSuite`, `ViewSuite`, `SettingsSuite`, `CoreTestSuite`, `MouseTargetIdSuite`, `SmallBodiesIdSuite`), their requirement tokens and `get_method_requirements()`, `add_project_info()`, and `IVAssistantTestSuite.parse_body()` and `get_global_position()`. They remain for projects that haven't moved; SPECIFICATION.md §4.7 maps each method to its replacement.

### Fixed
* `tools/orbit_accuracy_test.py` compared simulator positions with Horizons kilometers unconverted, off by a factor of 1000 since the Planetarium's `METER` became 1; it converts by the declared `IVUnits.KM`.
* `tools/assistant_test.py --launch` ran a hard-coded Godot executable unless given `--godot`; it now runs the newest build of the project's Godot major, chosen by new `tools/godot_executable.py`, which every launching script shares and which refuses rather than open the project with another major.


## [v0.0.4] - 2026-10-15

Released using Godot 4.7.2. This release coincides with Core plugin release v0.2.2.

### Changed
* SPECIFICATION.md's `list_actions` and `press_action` examples no longer use `toggle_orbits`, `toggle_names` or `toggle_symbols`, which Core v0.2.2 removes.


## [v0.0.3] - 2026-10-15

Released using Godot 4.7.2. This release coincides with Core plugin release v0.2.1.

### Added
* Command-line arguments `--assistant-port` and `--assistant-instance` (after `--`) override the configured port and tag the process, so one machine can run several instances at once; `get_project_info` reports `process_id`, `port` and `instance_id`. `GodotLauncher` in `tools/assistant_test.py` uses them: `port=0` launches on a free port, `check_instance()` verifies a client reached its own instance, and the launched Godot dies with its script on Windows. See SPECIFICATION.md §7.3.
* `--headless` option for `tools/assistant_test.py`, which skips the mouse-hover test.
* `move_camera` takes a `tracking` parameter (`"ground"`, `"orbit"` or `"ecliptic"`), which decides what frame its `view_position` longitude and latitude are measured in; omitted, the camera's current mode is left alone. Without it an agent could only pose in whatever frame the session happened to be in — and the default is not body-relative, so "put the camera 20 degrees above the equator" was not expressible at all.
* Method `set_camera_fov` in the control suite, which zooms the current camera by field of view or focal length.
* Method `set_huds` in the control suite, which sets orbit lines, names, symbols and the small-body point groups at once and absolutely. The `toggle_*` actions could not give an agent a clean frame to judge a render in: each is a toggle whose result depends on the state the session started in, so a cached view that already hides the HUDs has them *shown* by `press_action toggle_orbits`. `screenshot`'s `hide_gui` was never enough either — it hides the 2D GUI and leaves every 3D overlay drawing over the subject. The resulting flags come back in the result so a caller can confirm rather than assume.
* Methods `list_cached_views` and `apply_cached_view` in the view suite, so an agent can reproduce a staging the user set up and saved by hand rather than hunting for it by trial and error. `apply_cached_view` takes the view's `name` and its `collection`; `list_cached_views` reports both, alongside the same decoded fields `list_views` gives for the built-in views.

### Changed
* `project_to_screen`, `project_small_body_to_screen` and `get_hover_target` report window pixels, the same pixels `warp_mouse` takes and `screenshot` captures, now that the Core plugin's display scale puts the GUI in logical pixels on a hi-DPI screen (new static `IVAssistantTestSuite.to_window_pixels()`).


## [v0.0.2] - 2026-08-01

Released using Godot 4.7.1. This release coincides with Core plugin release v0.2.

### Changed
* Various updates for Core plugin v0.2.


## v0.0.1 - 2026-06-29

Released using Godot 4.7. This release coincides with other ivoyager plugin releases at v0.1.2.

### Added
* TCP server (IVAssistantServer autoload) providing a JSON-RPC-style interface on port 29071 for AI testing and accessibility.
* State queries: `get_state`, `get_time`, `get_selection`, `get_camera`, `list_bodies` (with filter for stars, planets, dwarf_planets, moons, spacecraft).
* Body queries: `get_body_info`, `get_body_position`, `get_body_orbit`, `get_body_distance` with optional time parameter.
* Selection navigation: `select_navigate` supporting up, down, next, last, and type-specific traversal (planets, moons, stars, spacecraft, major moons, history).
* Camera control: `move_camera` with optional target, view position, view rotations, and instant move.
* Time control: `set_time` supporting absolute TT seconds, Gregorian date arrays, and OS time sync.
* Basic controls: `select_body`, `set_pause`, `set_speed` (by index, delta, or real_time).
* Application quit: `quit` with optional `force` parameter for clean shutdown.
* EditorPlugin autoload registration: enable the plugin in Project Settings → Plugins and it works — no project-level config changes needed.
* Configuration via `ivoyager_assistant.cfg` with override support from `ivoyager_override.cfg`. Server only starts if enabled and (optionally) only in debug builds.
* Bash helper script `tools/assistant_client.sh` for command-line interaction with the server.
* Cross-project compatibility: two-phase TCP startup (listens on `core_initialized`, full API on `simulator_started`) supporting projects with splash screens.
* Project info: `get_project_info` returns project name, version, assistant name, capabilities, and optional context.
* Game start: `start_game` allows AI clients to bypass splash screens for automated testing.
* Configuration: `assistant_name` and `context_file` config keys for project-specific assistant identity.
* Screenshot capture: `screenshot` method saves viewport to PNG with optional `hide_gui` parameter for clean 3D captures.
* GUI visibility control: `show_hide_gui` method to show/hide all GUI panels (pulled forward from Phase 4 as a screenshot prerequisite).
* State vectors: `get_body_state_vectors` returns position and velocity vectors for orbital mechanics testing.
* Action emulation: `press_action` injects real `InputEventKey` events into Godot's input pipeline, enabling programmatic triggering of any user hotkey action.
* Action listing: `list_actions` returns all registered input actions with display names from `IVInputMapManager`.
* Modular test suite architecture: `IVAssistantTestSuite` RefCounted base class, `[assistant_test_suites]` config section, runtime suite loading with override-config support. Server reduced to TCP infrastructure plus four built-in methods (`get_project_info`, `get_state`, `start_game`, `quit`). Default suites: `StateQuerySuite`, `ControlSuite`, `CoreTestSuite`, `GuiInspectionSuite`.
* Save/load: `save_game` (`quicksave` / `named` / `autosave`), `load_game`, `get_save_status`. Available only when the `ivoyager_save` plugin is present and enabled. Async — poll `get_state`'s `is_saving` / `is_loading` for completion.
* GUI inspection (`GuiInspectionSuite`): `find_nodes` (by class / script class_name / name pattern), `inspect_node` (typed property tree to a configurable depth), `read_node_text` (visible-text harvest in document order; tab-aware, fold-aware). Generic scene-tree introspection that works on any GUI node without per-widget custom code.
* `period` field added to `get_body_orbit` result (in addition to the orbital elements).
* `orbit_class` field added to `get_body_orbit` result (orbit model script class, e.g. `"IVOrbit"` or `"IVRealPlanetOrbit"`). Lets clients tell whether long-baseline element evolution applies.
* Automated test runner: `tools/assistant_test.py` implements the full generic test sequence (SPECIFICATION.md section 9.3) as a Python script. Capability-aware, skips unsupported features. Supports `--launch`, `--skip-save`, `--host`, `--port` options.
* Orbit accuracy test: `tools/orbit_accuracy_test.py` compares sim positions of 8 moons and the 4 inner planets against embedded JPL Horizons reference vectors via `get_body_position`, asserting parent-centered angular separation within per-body tolerances. Moons are checked at two near dates (2010, 2026); planets additionally at far dates (years 2500, 2900) to exercise long-baseline mean-anomaly rate. Catches gross orbit propagation errors (element misinterpretation, epoch conversion, reference basis conventions, mean-motion vs mean-longitude rate). Cross-project safe: skips bodies a project doesn't load, and skips the far-date planet checks (rather than failing them) when the project builds plain `IVOrbit` planets instead of `IVRealPlanetOrbit` (detected via `get_body_orbit`'s `orbit_class`). Supports `--launch` (auto-detects the Godot executable matching the project's `config/features` major), `--bodies` subset filter, `--host`, `--port`.
* Readiness gate after `simulator_started`: sim-gated TCP methods now wait `min_ready_delay_frames` consecutive frames (default 10) of `ready_predicate` returning true before becoming available. Default predicate is trivially true, so the default behavior adds only a ~10-frame buffer after `simulator_started`. Projects with deferred main-thread initialization that continues past `simulator_started` (e.g. cross-thread arrival of game-state objects via `call_deferred`) can supply a `ready_predicate: Callable` to gate the server until their state has settled. New `IVAssistantServer.is_ready()` getter exposes the gate state to test suites that opt out of the suite-wide gate (e.g. `CoreTestSuite`); `save_game` and `load_game` now use this getter instead of `IVStateManager.started` directly. Gate re-arms across save/load cycles via the existing `about_to_free_procedural_nodes` reset.
* Mouse-hover identification (`MouseHoverSuite`): `warp_mouse` (synthesizes `InputEventMouseMotion` at a viewport pixel), `project_to_screen` (world-to-pixel via `Camera3D.unproject_position()` for a body, body-orbit point, raw world position, or asteroid in an `IVSmallBodiesGroup`), `get_hover_target` (reads `IVMouseTargetLabel.text` / `visible`), `list_small_body_groups` (enumerates loaded SBGs for asteroid hover staging). Capability `mouse_hover`. Covers all three classes of element identified by `IVFragmentIdentifier` today: body bounding-circle picks (`body`), single-body orbit lines (`body` + `time`), and SBG asteroid points (`small_body`). Reads the user-visible label rather than any specific identifier API, so tests written against this suite remain valid across replacement of the underlying identification mechanism (e.g. a future Compositors-based system replacing `IVFragmentIdentifier`).

### Changed
* Completed doc comments in all files.
* Declarative per-method requirement gating: suites declare prerequisites via `IVAssistantTestSuite.get_method_requirements()` against a closed token vocabulary (`core.*`, `program.*`, `autoload.*`, `body_table.*`, `widget.*`, `runtime.*`) defined in `IVAssistantServer.KNOWN_TOKENS`. Methods whose tokens resolve false are dropped from the dispatch table and listed under `gated_out` in `get_project_info` with the unmet token names. Suites can also opt out wholesale via `is_applicable()`. Built-in suites (`StateQuerySuite`, `ControlSuite`, `CoreTestSuite`, `MouseTargetIdSuite`) now use this path; their hand-rolled `get_capabilities()` filtering and redundant in-dispatch availability checks are removed. Test-suite loading is deferred from `_ready()` to `_on_core_initialized()` so tokens resolve against fully-initialized state. `widget.*` and `runtime.*` tokens re-evaluate on `simulator_started`.
* Manifest v2: `get_project_info` adds `assistant_protocol_version: 2`, a `methods` map (per-method summaries, reserved for future fields), and a `gated_out` array (one entry per registered-but-unavailable method, with unmet tokens). The `capabilities` array remains canonical and is rebuilt from active method names plus suite-supplied feature flags.
* `MouseHoverSuite` renamed to `MouseTargetIdSuite` (file `mouse_target_id_suite.gd`, capability string `mouse_target_id`). The "hover" framing was loose; the suite supplies primitives for mouse-driven on-screen-target identification (warp, project, read).

### Removed
* `MouseTargetIdSuite` (was `MouseHoverSuite`) no longer owns `IVSmallBodiesGroup`-based projection. The `small_body` mode of `project_to_screen` and `list_small_body_groups` are split into the new `SmallBodiesIdSuite` (file `small_bodies_id_suite.gd`, capability string `small_bodies_id`). The new suite gates both methods on `runtime.IVSmallBodiesGroup` (resolved at `simulator_started`), so projects that don't load any `IVSmallBodiesGroup` instances see the methods drop from the manifest. The asteroid projection method is now `project_small_body_to_screen` with flat `group` / `index` parameters (no nested `small_body` object). `tools/assistant_test.py` updated to match.


[v0.0.4]: https://github.com/ivoyager/ivoyager_assistant/compare/v0.0.3...v0.0.4
[v0.0.3]: https://github.com/ivoyager/ivoyager_assistant/compare/v0.0.2...v0.0.3
[v0.0.2]: https://github.com/ivoyager/ivoyager_assistant/compare/v0.0.1...v0.0.2
