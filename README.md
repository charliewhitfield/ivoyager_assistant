# ivoyager_assistant

AI assistant for accessible solar system navigation. Also provides AI interface for development tests.

UNDER DEVELOPMENT!

Today the TCP server (JSON-RPC on `localhost:29071`) is usable for AI-driven testing — state queries, body queries, controls, views, HUD visibility, screenshots, save/load, action emulation, mouse-target identification, and generic GUI inspection. The port can be set per process on the command line (`-- --assistant-port=<port>`), so several instances of a project can run at once. `tools/` holds a Python client and test runner. Accessibility features (voice control, screen reader, spatial audio) are planned.

This plugin will provide an interface so that AI can navigate the solar system, change anything accessible in the GUI (options, HUDs visibilities and colors, etc.), know what's on screen, and check on what's happening elsewhere. The motivation is twofold:

1. So AI can conduct tests (prerequisite to any serious AI-assisted coding).
2. So the Planetarium and other I, Voyager apps can be more accessible, for example, allowing navigation around the solar system via voice control.

The plugin itself is being developed using Claude Code. See Claude's specs and plans in:

- SPECIFICATION.md — the protocol, every method, configuration and the test tools
- CODING_PLAN.md — what is done and what is planned
