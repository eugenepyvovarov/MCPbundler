# Importing Servers

## Overview
MCP Bundler can import server definitions so you do not have to retype commands, URLs, or headers by hand. Imports always open a review sheet where you can confirm, edit, or skip entries.

## Import Sources
- Client config files: import from supported MCP client configs (Cursor, Claude, LM Studio, etc.).
- Manual JSON: paste JSON when you have a custom server definition.
- Install links: open a `mcpbundler://install/...` link from a partner or teammate.

## What Happens During Import
- The app reads the source and builds a list of candidates.
- Each candidate shows required fields (command or URL), optional settings, and warnings.
- You pick which servers to import and where to place them.

## Install Links
Install links are shareable URLs that contain a base64-encoded payload.

Format:
- `mcpbundler://install/server?name=<alias>&config=<base64url-json>`
- `mcpbundler://install/bundle?name=<bundleId>&config=<base64url-json>`

Notes:
- The payload must be valid JSON encoded with URL-safe base64.
- Very large payloads are rejected (128 KB limit).
- Invalid entries are shown with warnings so you can fix them before importing.

## Client Install Instructions
The app ships install instructions for popular clients. These instructions power the "Headless connection" guidance and explain where to paste the MCP server config for each client.
