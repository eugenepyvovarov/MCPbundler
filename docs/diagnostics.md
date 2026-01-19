# Diagnostics and Data Integrity

## Logs
- MCP Bundler records activity and errors per project.
- Logs include MCP requests, responses, and errors from servers and skills.
- When available, logs include the client name and version for easier support.
- OAuth sign-in events and refresh attempts are recorded with `oauth.*` categories.

## Integrity Checks
MCP Bundler periodically checks for data issues such as:
- Duplicate server aliases.
- Corrupt or outdated capability caches.
- Orphaned environment variables.

If issues are found, the app offers a repair flow that:
- Creates a backup of the local database.
- Cleans up invalid rows and rebuilds cached data.

## Advanced: Store Location
The local database lives at:
- `~/Library/Application Support/Lifeisgoodlabs.MCP-Bundler/mcp-bundler.sqlite`

You can override this path with `MCP_BUNDLER_STORE_URL` if needed.
