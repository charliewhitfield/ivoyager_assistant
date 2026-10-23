# ivoyager_assistant

AI assistant that operates an app for its user, by text or voice. Also provides AI interface for development tests.

UNDER DEVELOPMENT!

Today the TCP server (JSON-RPC on `localhost:29071`) is usable for AI-driven testing. The plugin knows Godot, not the project: a project's classes declare what a client may read and call (`AUTOMATION_*` constants), and `describe`, `get` and `call` find and use those declarations, so a change in Core or a project needs no change here. Widgets are listed and operated as a user operates them, named by their accessibility properties. Screenshots, action emulation, mouse-target identification and GUI inspection are built in. The port can be set per process on the command line (`-- --assistant-port=<port>`), so several instances of a project can run at once. `tools/` holds a Python client and test runner. The assistant itself is under way: `IVAssistant` reaches the app in process, through the same declarations, in any build a project enables it in, the web included, a project gives it instructions and tool sets, and the user connects it to a model, local or remote, in a setup wizard. Still to come are a conversation loop and a chat box.

This plugin will provide an interface so that AI can navigate the solar system, change anything accessible in the GUI (options, HUDs visibilities and colors, etc.), know what's on screen, and check on what's happening elsewhere. The motivation is twofold:

1. So AI can conduct tests (prerequisite to any serious AI-assisted coding).
2. So a user can ask an AI of their choosing, by voice or text, to operate the app for them: in the Planetarium, to take them around the solar system and explain what they see. This makes the app more accessible. The model is never part of the plugin; the user connects one, local or remote, or the project ships one beside the app.

The plugin itself is being developed using Claude Code. See Claude's specs and plans in:

- SPECIFICATION.md — the protocol, every method, configuration and the test tools
- CODING_PLAN.md — what is done and what is planned
