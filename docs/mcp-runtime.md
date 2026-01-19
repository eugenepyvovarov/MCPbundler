# MCP Server Runtime

## Overview
MCP Bundler combines multiple MCP servers into a single MCP endpoint. This gives clients one connection while still keeping each server separate under the hood.

## Namespacing
- Each server has an alias.
- Tools and prompts are exposed as `alias__name` so names never collide.
- Resources are wrapped so the client can always read them through MCP Bundler.

Example:
- Server alias: `docs`
- Tool: `search`
- Exposed name: `docs__search`

## Tool Calls
- When a client calls a tool, MCP Bundler routes it to the correct server.
- Skills are exposed as standard MCP tools so clients without special skill support can still run them.
- If a server is unavailable, the client receives a clear error message.

## Context Optimizations
Context Optimizations reduce large tool lists. When enabled:
- "Hide MCP tools under Search/Call Tools" replaces the full tool list with two meta tools.
- `search_tool` lets clients discover available tools on demand.
- `call_tool` invokes any namespaced tool and returns the normal response.
- Direct calls to `alias__tool` still work for clients that already know the name.

## Large Responses and Temp Files
Large responses can be stored as temp files to keep the response small:
- Enable "Store large tool responses as files" in project settings.
- Responses above the threshold are written to the temp folder.
- The client receives a short pointer message and can read the file with `fetch_temp_file`.

## Skills for Clients Without Resource Support
Some clients do not support MCP `resources/read`. MCP Bundler exposes `fetch_resource` so those clients can still access skill resources using a simple tool call.
