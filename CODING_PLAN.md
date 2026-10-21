# I, Voyager Assistant — Coding Plan

## Status

v0.0.5.dev. The TCP server, modular test suite architecture, and the generic state / control / body / camera / view / time / selection / speed / HUD / settings / save / load / GUI-inspection / mouse-target / screenshot / action-emulation APIs are all in place, plus a Python test runner that can run several instances at once. Remaining work centers on automation (classes declaring their own Assistant interaction) and accessibility.

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

## Next: Automation — classes declare their own interaction

Today the Assistant knows Core. Its suites and server refer to about 25 Core classes, so a change in Core means a change here. Its gating is a closed token vocabulary (`SPECIFICATION.md` §7.5) that the server must extend for each new condition, and a method with no token is assumed available. Under automation the Assistant knows only Godot and one convention: any class — a Core program object, singleton, tree node or widget, or a project's own — declares what a client may read and call. This is the `PERSIST_*` pattern: the class declares, a scanner reads, and the class never refers to the scanner. Core's declarations are then the templates a project follows.

This replaces the earlier "Suite B" widget-actuation plan, which becomes one case of it (*Widgets* below).

### The convention

Constants are prefixed `AUTOMATION_`; methods and properties carry `automation` after Godot's verb (`get_automation_value()`, `is_automation_available()`). Godot's `accessibility_*` properties keep their own names. Nothing in a declaring class refers to the Assistant.

- `AUTOMATION_METHODS: Array[StringName]` — methods a client may call.
- `AUTOMATION_PROPERTIES: Array[StringName]` — properties a client may read. Writes go through methods.
- `AUTOMATION_KEY: Array[StringName]` — for a class with several instances, the properties that tell one from another (`IVBody`: `name`; `IVNavButton`: `body_name`; `IVHUDsCheckBox`: `hud_type`, `body_flags`, `sbg_aliases`). A class with one instance needs none.
- `is_automation_available(member: StringName) -> bool` (optional) — the class owns its gates.
- `get_automation_objects() -> Dictionary[StringName, Object]` (optional) — further objects, by role name. `IVGlobal` returns its `program` dictionary, so program objects that are not nodes are found too, under a role (`SpeedManager`) that survives a project substituting its own subclass.

```gdscript
# timekeeper.gd
const AUTOMATION_METHODS: Array[StringName] = [&"get_time", &"set_time",
		&"set_time_from_date_clock_elements", &"set_operating_system_time_sync"]

func is_automation_available(member: StringName) -> bool:
	if member == &"get_time":
		return true
	return IVCoreSettings.allow_time_setting
```

The §10 layering principle becomes guidance for the declaring class: declare the entry point a GUI widget calls. Declaring one below it (`IVCameraHandler.move_to`) is the marked exception, and its doc comment says so.

### What the Assistant does with it

- **Finds objects using only Godot:** autoloads, the scene tree, and whatever `get_automation_objects()` names. It resolves an address at call time, so procedural objects freed on a reset simply drop out. A single object is addressed by its role or autoload name, one of several by class and key.
- **Reads signatures at runtime.** `get_script_method_list()` gives argument names and types, typed-array element types, defaults and the return type, and marks an enum argument with its enum, whose value names come from the script's constant map (checked in Godot 4.7.2). So JSON arguments convert to typed ones without knowing the class: enums by name, vectors from arrays, and a parameter typed with a class that declares `AUTOMATION_KEY` from its key — a method may take an `IVBody` and the client passes a name. Results convert back the same way.
- **Gates by presence.** A member is listed and callable only when its object exists and `is_automation_available()` agrees. Nothing is assumed, and the token vocabulary retires.
- **Describes everything in one call** (provisionally `describe`): every object, member, signature, enum value name, description and availability, generated from the running app. That is a client's whole context in one place, and anything absent from it is something the project does not offer.
- **Separates two surfaces by Godot class.** `Control`s and the input actions of `list_actions` are the user surface: what a user can do, and all an accessibility client should do. Everything else is the test surface, which reaches state however the GUI looks. No class declares which it is. A project without a focal-length control offers no FOV change on the user surface, even where `IVCamera` declares `set_focal_length` for tests.
- **Accepts JSON-RPC 2.0 batch arrays**, so a client composes several calls in one round trip. The server rejects arrays today.

### Descriptions: the doc comments

A declared member's `##` doc comment is its description: one copy, already written from a caller's point of view. No runtime API exposes doc comments (checked in 4.7.2), so the Assistant parses them from source. Doc-comment quality becomes part of what a client depends on.

- In a run from the project directory, the `.gd` source is there to parse.
- An export ships scripts as binary tokens (`.gdc`), without comments. The Assistant's editor plugin therefore registers an `EditorExportPlugin` that parses the declaring scripts in `_export_begin()` and adds the digest to the export with `add_file()`. At runtime the Assistant reads source where it exists and the digest otherwise; one parser serves both.

### Widgets

A widget follows the same convention, and the Assistant adds what it knows of Godot's `Control` families. Operating a widget runs the widget's own handler, which calls the same Core method a user's click does.

**Meaning: Godot's accessibility properties.** A widget says what it is with `accessibility_name` and `accessibility_description`, names its label with `accessibility_labeled_by_nodes` (a HUDs-grid checkbox, labeled by its row and column) and names what it opens with `accessibility_controls_nodes` (an `IVPanelButton` and its panel). AccessKit hands the same properties to a screen reader, so this work serves Phase 5 too, and no widget carries a second, AI-only description. Godot's accessibility tree is write-only from script, so the Assistant reads the `Control` properties, falling back to `text` and `tooltip_text` where they are unset. Core sets none of them today.

**Identity: a key, not a path.** Paths break when a GUI is rearranged, widgets built at runtime have generated names (`IVHUDsBox`'s checkboxes), and displayed text is translated, so a widget with several instances declares `AUTOMATION_KEY`. A node path remains the fallback for a control with no script; an address that matches more than one widget is an error listing the candidates.

**Operation: per-family defaults.** Each family is operated the way that fires everything a user's operation fires, which a property setter often does not. Measured in Godot 4.7.2:

| Family | Operation | Why |
|---|---|---|
| `BaseButton` (`Button`, `CheckBox`, `CheckButton`; toggle or not, grouped or not) | Focus it, deliver `ui_accept` to its viewport (the keyboard user's path), restore focus | No script call fires everything a click does. The `button_pressed` setter fires `toggled` and `_toggled()` but not `pressed` or `_pressed()`; emitting `pressed` skips `_pressed()` and the toggle. Core relies on each: `IVNavButton._pressed()`, `IVSymbolPicker` on a grouped toggle's `pressed`, `IVTrackCkbxs` on `ButtonGroup.pressed`. |
| `Range` (`Slider`, `SpinBox`, ...) | Set `value` | Fires `value_changed`. |
| `TabContainer` | Set `current_tab` | Fires `tab_selected` and `tab_changed`. |
| `FoldableContainer` | `fold()` / `expand()` | The `folded` setter fires nothing. |
| `OptionButton` | `select()`, then emit `item_selected` | Neither `select()` nor the `selected` setter fires it. |
| `LineEdit` | Set `text`, emit `text_changed`; emit `text_submitted` on request | The setter fires nothing. |
| `TextEdit` | Set `text`, emit `text_changed` | The setter fires only `text_set`. |

Delivered through a viewport, `ui_accept` meets `_input()` handlers before the focused button, and one that consumes it would swallow the press. A widget whose handling no default reproduces declares the value interface below instead.

**Composite widgets: their own value interface.** A widget whose state is not one control's (`IVSpeedButtons`, `IVTimeSetter`, `IVTrackCkbxs`) declares `get_automation_value()` and `set_automation_value(value)`, plus `get_automation_options()` where the value is one of a set. `set_automation_value()` must call the Core method the widget's own handlers call. The Assistant treats such a widget as one unit and neither lists nor operates its child controls; a container without the interface (`IVHUDsBox`) is descended.

**Reach.** Popups are in-tree `Window`s, and a widget meant for automation exists in the tree, hidden if need be, so its absence from `describe` means the project lacks it. A hidden widget is reached by operating its opener first; no project configures scene roots.

**Guards:**
- Refuse a disabled, non-editable or hidden widget with an error, never a silent no-op. For a hidden one, name the control whose `accessibility_controls_nodes` reveals it.
- Never synthesize a click at a screen position: nothing is hit-tested, so overlapping controls, GUI scale and headless runs don't matter.
- Echo the resulting state (e.g. `{"ok": true, "pressed": true}`) so the client can confirm without a follow-up read.

### What stays in the Assistant

Transport and protocol; discovery, conversion and the doc digest; and the Godot-level tools — GUI inspection, the `Control` family defaults, `press_action` / `list_actions`, `warp_mouse`, `screenshot`, `quit` and `get_project_info`. Its last Core knowledge is the server's lifecycle hooks (`core_initialized`, `simulator_started`, `start_game`); how `IVStateManager` declares them is open.

### Decisions

- Helpers that combine several objects or exist only for tests (`get_state`, the HUD handling around `screenshot`, the bulk HUD setters) become client compositions over batch calls. The suite mechanism remains only for project-specific helpers.
- Declared members are public API. Renaming or removing one is `[API breaking]` in the declaring repository's changelog; it breaks client scripts, never the Assistant.
- `SPECIFICATION.md` defines the convention, since it defines the protocol. Core follows it as it follows Godot's accessibility properties, without referring to the plugin.

### Work

Old and new coexist until the last suite retires.

1. Assistant — discovery, `describe`, conversion, availability, batch, the source parser and the export digest; the convention in `SPECIFICATION.md`; a protocol version bump.
2. Time, speed and pause end to end (`IVTimekeeper`, `IVSpeedManager`, `IVStateManager`): the proof, and the template for the rest.
3. The remaining Core areas one at a time (camera and views, selection, bodies, HUDs, settings, save, mouse targets), retiring each suite's methods as clients move; `tools/assistant_test.py` moves from method names to described members.
4. Widgets — accessibility properties, keys and value interfaces across Core's `ui_widgets/` and `ui/`, and the `Control` family defaults in the Assistant.
5. The lifecycle hooks, after which the Assistant refers to no Core class.

## Next: Phase 5 — Accessibility

**Goal:** make the Planetarium navigable via voice control and screen readers.

Purely conceptual at this stage; no detailed API yet.

### Step 5.1: Voice command interface

- Design grammar mapping natural language to existing API methods.
- Integration with speech-to-text services.

### Step 5.2: Screen reader support

- Widgets name and describe themselves through the accessibility properties the automation work fills in.
- Text descriptions of current view and selected body.
- Announce state changes (`accessibility_live`).

### Step 5.3: Spatial audio

- Audio cues for body positions relative to camera.
- Directional feedback for navigation.
