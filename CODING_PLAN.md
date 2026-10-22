# I, Voyager Assistant — Coding Plan

## Status

v0.0.5.dev. Classes declare their own Assistant interaction (automation, `SPECIFICATION.md` §11), and the Assistant discovers and dispatches it — `describe`, `get`, `call`, batches, widget listing and operation — knowing only Godot. The earlier suites are removed. Remaining work: accessibility.

For the per-method addition history, see `CHANGELOG.md`. For the protocol and configuration reference, see `SPECIFICATION.md`.

## Completed

- **Phase 1–2** — TCP server + JSON-RPC protocol; state/body/camera/time/selection/speed APIs; basic controls (`select_body`, `set_pause`, `set_speed`); EditorPlugin autoload registration.
- **Phase 2.5 — Cross-project compatibility** — two-phase startup (`core_initialized` → `simulator_started`); `get_project_info`, `start_game`; `assistant_name` / `context_file` config keys; graceful sim reset on `about_to_free_procedural_nodes`.
- **Phase 3 — Testing utilities** — `screenshot` (with `hide_gui`), `show_hide_gui`, `get_body_state_vectors`.
- **Phase 3b — Action emulation** — `list_actions`, `press_action`.
- **Phase 3c — Modular test suite architecture** — `IVAssistantTestSuite` RefCounted base class, `[assistant_test_suites]` config section, four default suites; server reduced to TCP infrastructure plus four built-in methods.
- **GUI inspection** (`GuiInspectionSuite`) — `find_nodes`, `inspect_node`, `read_node_text`. Generic scene-tree introspection that subsumes much of the originally planned Phase 4.
- **Save/load** (in `CoreTestSuite`) — `save_game`, `load_game`, `get_save_status`. Available only when `ivoyager_save` is present.
- **Readiness gate** — `ready_predicate` + `min_ready_delay_frames` + `IVAssistantServer.is_ready()`. Lets projects with deferred main-thread initialization gate save/load and similar operations until state has settled.
- **Test runner** — `tools/assistant_test.py` implements the SPECIFICATION.md §9.3 sequence; capability-aware, skips unsupported features.
- **Phase 3d — Mouse hover identification** (`MouseTargetIdSuite`, plus `SmallBodiesIdSuite` for asteroid points) — `warp_mouse`, `project_to_screen`, `get_hover_target`, `project_small_body_to_screen`. Positions are in window pixels, the same as a screenshot's. Lets tests verify that hovering at a given screen position identifies the expected element by reading `IVMouseTargetLabel.text`. The suite never references `IVFragmentIdentifier` directly, so it serves as a regression safety net for the upcoming replacement of that class with a more efficient identifier (e.g. Compositors-based) — tests written today should continue to pass after the swap, validating that the user-visible effect is preserved.

- **Phase 3e — Views** (`ViewSuite`) — `list_views`, `apply_view`. Binds Tier-1 camera framing to `IVViewManager.set_table_view` — the same Core call the GUI's default `IVViewButton` makes — so an agent frames the camera the way a user clicks a view button, instead of hand-building a perspective-distance vector through `move_camera`. (`move_camera` has since gained a `tracking` parameter, and `set_camera_fov` sets zoom.) `list_views` decodes each table view's target, tracking mode, up-lock, framing vector, and affected state categories (`IVView` has no description field). `list_cached_views` / `apply_cached_view` later added the user's own saved views. Established the "Core surface classes / layering principle" (`SPECIFICATION.md` §10): Assistant methods bind to the same Core entry points GUI widgets do, at the same level; sub-surface access (e.g. `move_camera`) is the marked exception. Also corrected the `IVCamera` / `IVCameraHandler` / `IVViewManager.set_table_view` doc comments to state the perspective-distance contract in caller terms and point to views as the normal path.
- **HUD visibility** (in `ControlSuite` and `SmallBodiesIdSuite`) — `set_huds` (hides or shows everything at once, as the GUI's hide-HUDs button does), `set_all_body_orbits_visibility`, `set_body_orbit_visible_flags`, `set_small_body_points_visibility`. The per-flag setters return the previous state so a test can restore it.
- **Parallel instances** — `--assistant-port` / `--assistant-instance` command-line arguments, `process_id` / `port` / `instance_id` in `get_project_info`, and `GodotLauncher` (`tools/assistant_test.py`) launching on a free port, tied to its script and held to one logical processor per core.
- **Phase 4 — Settings & HUD typed API** — `SettingsSuite` (`get_options`, `set_option`) binds where the Options popup does and names a dropdown setting's values from the popup's own enumerations; changes stay unpersisted unless asked. `get_huds` and `set_class_huds` (in `ControlSuite`) read and set HUD visibility by body class and small-body group, `set_class_huds` binding where the HUD checkboxes do. Core gained `IVSettingsManager.get_setting_keys()` for it. These expose state by named flag, not by GUI text; `find_nodes` / `read_node_text` remain the tools for asserting that GUI text renders. `get_gui_state` from the original Phase 4 plan was dropped, superseded by the GUI inspection suite.
- **Automation** — Any class declares what a client may read and call: `AUTOMATION_METHODS`, `AUTOMATION_PROPERTIES`, `AUTOMATION_KEY`, `is_automation_available()`, `get_automation_objects()`, and on one autoload `AUTOMATION_LIFECYCLE`. The server finds declaring objects among autoloads, named roles and the scene tree; serves `describe` (the whole context: objects, keyed classes, signatures, doc comments, enums, availability, visible widgets, actions), `get` and `call` with conversion by Godot's own type information; accepts JSON-RPC batches; and takes its lifecycle from the declaration, so it refers to no Core class. Doc comments are parsed from source, and an `EditorExportPlugin` digests them into exports. Widgets: listed and operated per Godot family (buttons through `ui_accept`, ranges, tabs, foldables, options, text), named by their accessibility properties, identified by key, composites through their own value interface, hidden ones reached through their opener. Core declares time, speed, state, settings, camera, views, selection, bodies and orbits, HUDs, small-body groups and its widgets; Units its unit constants. Suite methods that bind to Core were deprecated at first, then removed (below); `press_action`, `warp_mouse`, `screenshot`, `project_to_screen`, `list_actions` and GUI inspection became built-in Godot-level tools. `tools/assistant_test.py` and `orbit_accuracy_test.py` moved to declared members (the latter fixing a factor of 1000 since the Planetarium's `METER` became 1).
- **Suites removed** — `IVAssistantTestSuite`, the `[assistant_test_suites]` config section, the Core-bound suites and their requirement tokens are gone, once Astropolis had moved its own test probes to declared members; the built-in tools are plain classes the server dispatches, and `get_project_info` (protocol 5) drops `methods` and `gated_out`. A project's probes are classes that declare members (`SPECIFICATION.md` §7.2): the Planetarium's `ExposureProbe` and `DialogRigProbe`, the tools submodule's icon capture. `tools/assistant_test.py` saves and loads through `IVSave`'s declarations, and `SPECIFICATION.md` §4.7 keeps the map from each removed method to its replacement.


## Open, not blocking

- A widget that updates itself a frame later (the focal-length spin box, a popup button) echoes its old state from `operate_widget`. Replying a frame later would fix it at the cost of a deferred response path in the server.
- `describe` with widgets runs to ~90 KB in the Planetarium, most of it the 45 navigation buttons and the per-member doc comments; a client that needs less passes `widgets: false` or reads `list_widgets` filtered.
- Godot-native members a class declares (`name`, `global_position`, `visible`) have no description; the class reference isn't available at runtime.

## Next: Phase 5 — Accessibility

**Goal:** make the Planetarium navigable via voice control and screen readers.

Purely conceptual at this stage; no detailed API yet.

### Step 5.1: Voice command interface

- Design grammar mapping natural language to existing API methods.
- Integration with speech-to-text services.

### Step 5.2: Screen reader support

- Widgets name and describe themselves through their accessibility properties (in Core since the automation work); fill in the rest (data panels, popups' contents) and check what a screen reader reads.
- Text descriptions of current view and selected body.
- Announce state changes (`accessibility_live`).

### Step 5.3: Spatial audio

- Audio cues for body positions relative to camera.
- Directional feedback for navigation.
