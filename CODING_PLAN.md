# I, Voyager Assistant — Coding Plan

## Status

v0.0.5.dev. Classes declare their own Assistant interaction (automation, `SPECIFICATION.md` §11), and the Assistant discovers and dispatches it — `describe`, `get`, `call`, batches, widget listing and operation — knowing only Godot. The earlier suites are removed. Phase 5, the user's assistant, is under way: Step 5.1 is done, 5.2 is next.

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
- **Suites removed** — `IVAssistantTestSuite`, the `[assistant_test_suites]` config section, the Core-bound suites and their requirement tokens are gone, once the projects using them had moved their own test probes to declared members; the built-in tools are plain classes the server dispatches, and `get_project_info` (protocol 5) drops `methods` and `gated_out`. A project's probes are classes that declare members (`SPECIFICATION.md` §7.2): the Planetarium's `ExposureProbe` and `DialogRigProbe`, the tools submodule's icon capture. `tools/assistant_test.py` saves and loads through `IVSave`'s declarations, and `SPECIFICATION.md` §4.7 keeps the map from each removed method to its replacement.


## Open, not blocking

- A widget that updates itself a frame later (the focal-length spin box, a popup button) echoes its old state from `operate_widget`. Replying a frame later would fix it at the cost of a deferred response path in the server.
- `describe` with widgets runs to ~90 KB in the Planetarium, most of it the 45 navigation buttons and the per-member doc comments; a client that needs less passes `widgets: false` or reads `list_widgets` filtered.
- Godot-native members a class declares (`name`, `global_position`, `visible`) have no description; the class reference isn't available at runtime.

## Next: Phase 5 — Assistant

**Goal:** goal 2 of `SPECIFICATION.md` §1. A user talks, by text or voice, with an AI of their choosing, which operates the app for them through the same declarations a test client uses (§11). It works in any build, the web included.

Each step's API is designed when the step is built. The division of the work is settled:

- **The model is never part of the plugin.** It is a remote service, a local server the user runs (Ollama, LM Studio), or a server a project ships beside its app (5.8).
- **The plugin** provides connections to models and a setup wizard, the conversation loop, tool definitions generated from declared members, and a chat box.
- **The project** provides the assistant's personality, the tools it offers, which connections to offer (or one preset), and the chat box's theme and place. The Planetarium names its assistant Galileo and puts it in a panel at the bottom center.

The steps are in build order. The Planetarium is the first project to get an assistant, so the steps it needs come first, and a model shipped with an app (5.8) comes last. Facts about outside services below are as of October 2026; recheck them when the step is built.

### Step 5.1: An in-process client in shipped builds — done

- `IVAssistant`, a second autoload, is the user's assistant. `[assistant] enabled` turns it on, and it runs in every build; its `request(method, params)` answers in process what a TCP client would be answered. The conversation loop (5.5) calls it.
- `IVAssistantDispatcher` answers a request by its method (`describe`, `get`, `call`, the built-in tools). The server and `IVAssistant` each hold one, so a model's tool call takes a test client's path. Until 5.2 restricts it, `request` answers everything the server does.
- The server's keys moved to `[assistant_server]`; it stays debug-only and inert on the web. `[assistant]` keeps `assistant_name` and `context_file`, which both clients are given.
- The doc-comment digest (§11.5) goes into every export where the assistant is enabled or the server can run, and no other.

### Step 5.2: What an assistant may call

- `surface` (§4.2) marks only `Control`s as the user's. Also mark the declared methods a user's assistant may call: the widget-level entry points of §10, never a marked exception (`IVCameraHandler.move_to`) or a test probe.
- The assistant's own chat box is not a widget it operates.

### Step 5.3: The project's tools and personality

- A project names the declared members its assistant is offered, and adds tools of its own as members of its own classes (§7.2, as the Planetarium's probes are).
- `describe` runs to ~90 KB in the Planetarium, ~25K tokens. A large remote model takes that, and a provider's prompt cache makes resending it cheap; a small local model chooses well among 10–20 tools. So a project's tool list may differ by model size.
- Tools that look up the project's own data (the Planetarium's tables) let the model answer from the app rather than its memory, which matters most for a small model.
- A text description of the current view (selection, what is in frame, time, speed), declared once, serves both the assistant and a screen reader's announcements.
- The personality is the model's instructions, with `assistant_name`; `context_file` (§8.3) grows into it. The Planetarium's `assistant_context.txt` is written for a test client (probes, screenshots, `suppress_caching`), not for Galileo, so the two need separate texts or one split in two.

### Step 5.4: Connections and the setup wizard

- Two adapters cover nearly every model: OpenAI-compatible chat completions with tools (Ollama, LM Studio and llama.cpp's `llama-server` locally; OpenRouter, Groq, Gemini's compatibility endpoint and OpenAI remotely), and Anthropic's Messages API. A project may add its own adapter.
- The wizard finds local servers (Ollama on port 11434, LM Studio on 1234) and lists their models, or takes a provider and the user's key; either way it confirms the connection with one test tool call. A project offers a subset, or presets one connection and hides the wizard.
- Keys are the user's own, stored under `user://`; the wizard says so.
- Web: `HTTPRequest` runs on the browser's `fetch`, so a service must accept calls from a page (CORS). Anthropic does with the `anthropic-dangerous-direct-browser-access` header, and OpenRouter does. A local Ollama needs `OLLAMA_ORIGINS` set to the page's origin and the browser's local-network permission. Chrome's built-in model (the Prompt API, Gemini Nano) is free and on-device, but desktop Chrome only, with more than 4 GB of video memory: a candidate for a small assistant on the web.
- Consumer chat subscriptions don't include API access; Anthropic's terms reserve Pro and Max for its own apps. OpenAI's "Sign in with ChatGPT" plan usage lets an app spend a subscriber's allowance, so far for launch partners only. A subscription reaches the app today through MCP (5.6).

### Step 5.5: The conversation loop and the chat box

- The loop keeps the conversation and sends the instructions, tool definitions and history, stable parts first so a provider's prompt cache holds. It runs each tool call on the main thread as `call` does, returns a refusal (§3.3) to the model as the tool's error, and repeats until the model answers. It emits signals the chat box follows, and can be cancelled.
- The chat box is a widget a project themes and places. Replies go to an accessibility live region, so a screen reader reads them as they arrive; speaking them through `DisplayServer.tts_speak` is optional.

### Step 5.6: MCP

- Serve the assistant's tools as an MCP server, so a user's own AI application (Claude Desktop, LM Studio, ...) operates the app on their subscription or local model, with its own chat and voice.
- Native builds only. Opt-in in a release build, with a token: the TCP server has no authentication because it runs only in debug builds (§2.4).

### Step 5.7: Speech

- Out: Godot's text-to-speech (`DisplayServer.tts_speak`; the browser's speech synthesis on the web).
- In: whisper.cpp or the operating system's recognition natively; the Web Speech API on the web (Chrome sends the audio to Google).

### Step 5.8: A model shipped with the app

- A project that ships a model runs llama.cpp's `llama-server` beside the app as a child process. It speaks the OpenAI-compatible API, so it is one more preset connection, and an inference crash doesn't take the app down. The plugin starts it on a free port, waits until it answers and stops it at quit, as `GodotLauncher` does for test runs.
- The weights are a separate download, never in the plugin: a 3–4B-parameter model at 4 bits is ~2–2.5 GB, 7–8B ~5 GB. Their licenses vary (Qwen, Phi and Mistral's small models are Apache 2.0 or MIT; Llama has its own terms) and belong in the project's attributions.
- Small models choose reliably from a short tool list when the server holds their output to valid JSON, and are weak at multi-step plans and at facts. On the GPU, generation competes with rendering and costs frames; on the CPU it is slow (~5–15 tokens/s at 3–4B).
- Native builds only. The Planetarium could offer the same as a wizard choice: download a small model.

### Accessibility without AI

Screen-reader coverage (data panels, popups' contents, checking what a screen reader reads), announcements of state changes (`accessibility_live`) and spatial audio for bodies' positions relative to the camera need no model and aren't this plugin's: they are work in Core's widgets and a project's GUI. They are listed here until Core has a plan to hold them.
