# Headless STDIO

## Overview
Headless mode runs MCP Bundler as a background MCP server for CLI tools and automation. It serves the active project over STDIO so clients can connect without the GUI.

## Starting Headless Mode
- Launch the app with `--stdio-server`.
- The process uses the active project. If no project is active, headless mode will exit with a clear message.
- Headless mode expects one client per process. If the client closes STDIN, the process ends.

## Session Behavior
- Capabilities are loaded from cached snapshots so startup is fast.
- When you edit a project in the GUI, headless mode reloads the active session when possible.
- If a server is disabled or removed, headless mode stops serving it immediately.

## Environment Flags
- `MCP_BUNDLER_STORE_URL` lets you point the app at a different SQLite store.
- `MCP_BUNDLER_PERSIST_STDIO=0|1` controls whether provider caches stay warm after STDIO closes.
- `MCP_BUNDLER_STDIO_VERBOSE=1` enables verbose logs to stderr.
- `MCP_BUNDLER_SMOKE_TEST=1` enables the headless smoke test suite.

## List-Changed Notifications
If a client supports MCP list-changed notifications, headless mode will notify it when tools, prompts, or resources change after a project update.
