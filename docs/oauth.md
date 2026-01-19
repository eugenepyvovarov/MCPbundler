# OAuth for Remote Servers

## Overview
Some remote MCP servers require OAuth sign-in. MCP Bundler can handle the sign-in flow and store tokens so you do not need to paste them into headers manually.

## When You See OAuth
- OAuth is used only for remote HTTP/SSE servers.
- The server editor shows an OAuth status badge and a "Sign In" action when needed.

## Automatic Sign-In
- Click "Sign In" and MCP Bundler opens a browser window.
- After you approve access, the app saves the session and updates the status to "Authorized".
- Tokens refresh automatically in the background when possible.

## Manual Credentials
Some providers do not allow dynamic registration and require a manual client ID/secret.
- Toggle "Use manual OAuth client credentials" in the server editor.
- Enter the client ID and secret provided by the server.
- Run the sign-in flow again.

## Diagnostics and Logs
- OAuth activity is recorded in the project's logs under `oauth.*` categories.
- You can open the OAuth diagnostics panel from the server editor to view recent events.

## Atlassian Notes
Atlassian MCP servers are supported without the extra cloud ID lookup. If you see authorization errors, re-run the sign-in flow and review the OAuth diagnostics panel.
