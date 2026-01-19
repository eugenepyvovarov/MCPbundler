# Repository Guidelines

> **Spec Baseline**: All MCP lifecycle references should align with the 2025-06-18 MCP specification revision.

## Project Structure & Module Organization
- `MCPBundler/` holds the macOS SwiftUI app. Services live in `MCPBundler/Services/`, UI views under `MCPBundler/Views/`, and data models in `MCPBundler/Models/`.
- `MCPBundlerTests/` provides unit tests; each suite mirrors the production module (e.g., `BundledServerManagerTests.swift` exercises `Services/` logic).
- `MCPBundlerUITests/` stores the UI automation harness for future scenarios.
- `docs/` contains end-user documentation; `docs/specs/` only tracks OSS prep (`spec_open_source.md`).

## Documentation (Obsidian)
- Store project documents/specs/changelogs in the Obsidian vault `Thoughts`, under `Y26/P/MCPbundler/`.
  - Vault path (macOS/iCloud): `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Thoughts`
  - Project folder: `Y26/P/MCPbundler/`
  - Docs folder: `Y26/P/MCPbundler/Docs/`
- Mirror `docs/` into `Y26/P/MCPbundler/Docs/`.
- Mirror `docs/specs/spec_open_source.md` into `Y26/P/MCPbundler/spec_open_source.md`.
- Mirror `CHANGELOG.md` into `Y26/P/MCPbundler/Changelog.md`.

## Build, Test, and Development Commands
- `xcodebuild build -project MCPBundler.xcodeproj -scheme MCPBundler -destination 'platform=macOS'`: builds the debug app locally.
- `xcodebuild build-for-testing ... CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`: prepares test bundles quickly without signing.
- `xcodebuild test-without-building -only-testing:<Target/TestSuite>`: executes a specific suite using the cached build, ideal for fast verification.

### Headless STDIO Environment Flags
- `MCP_BUNDLER_STORE_URL=/tmp/.../mcp-bundler.sqlite`: override the default Application Support store, useful for tests or scratch sessions.
- `MCP_BUNDLER_PERSIST_STDIO=0|1`: default `1`; when set to `0` the headless runner tears down provider caches after stdin closes.
- `MCP_BUNDLER_STDIO_VERBOSE=1`: enables detailed stderr tracing for stdio startup/teardown and transport events.
- `MCP_BUNDLER_SMOKE_TEST=1`: opt-in gate for `HeadlessStdIOSmokeTests`; without it the suite skips by design.

## Coding Style & Naming Conventions
- Swift with 4-space indentation and ≤120-character lines.
- UpperCamelCase for types/protocols, lowerCamelCase for properties/functions, suffix SwiftUI views with `View`.
- Annotate stateful UI (`@StateObject`, `@Observable`) only when needed; prefer value semantics elsewhere.

## Testing Guidelines
- XCTest is the primary framework. In-memory transports replace shell scripts for deterministic coverage.
- Structure tests as `<ModuleName>Tests.swift` and mirror production filenames.
- Validate transport hygiene with `BundlerStdioTransportTests`; provider diffing with `BundledServerManagerTests`; preview/session logic with `StdiosessionControllerTests`.
- Run suites via `xcodebuild test-without-building` to minimize rebuild time.

## Commit & Pull Request Guidelines
- Use short, imperative commit subjects (e.g., “Refine stdio transport guard”) with contextual bodies when warranted.
- PRs should describe the change, list testing commands executed, and link relevant spec sections or issues. Provide screenshots for UI updates and summarize risk/rollout for behavioral changes.

## Architecture & Agent Notes
- OAuth dynamic client registrations use loopback redirects (http://localhost:<port>/oauth/callback) with client_uri=https://mcp-bundler.maketry.xyz; update both when onboarding new servers.
- Atlassian MCP servers do not require `X-Atlassian-Cloud-Id`; skip the accessible-resources lookup to avoid unnecessary 401 noise.
- Cross-process communication follows the MCP lifecycle: CLI helper ↔ macOS host app ↔ Bundler services. consult `docs/headless-stdio.md` for event-driven reload expectations.
- When editing services, ensure `ProjectSnapshotCache` and event emission stay in sync so headless and preview sessions STAY consistent.
- SQLite OAuth diagnostics location: `~/Library/Application Support/Lifeisgoodlabs.MCP-Bundler/mcp-bundler.sqlite`, table `ZLOGENTRY` (use `ZTIMESTAMP+978307200` to convert to localtime). OAuth entries use the `oauth.*` category prefix.
  - Quick queries:
    - List OAuth categories: `sqlite3 "$HOME/Library/Application Support/Lifeisgoodlabs.MCP-Bundler/mcp-bundler.sqlite" "select ZCATEGORY,count(*) from ZLOGENTRY where ZCATEGORY like 'oauth.%' group by 1 order by 2 desc;"`
    - Recent OAuth events: `sqlite3 -cmd ".mode tabs" "$HOME/Library/Application Support/Lifeisgoodlabs.MCP-Bundler/mcp-bundler.sqlite" "select datetime(ZTIMESTAMP+978307200,'unixepoch','localtime'), ZCATEGORY, ZLEVEL, ZMESSAGE from ZLOGENTRY where ZCATEGORY like 'oauth.%' order by ZTIMESTAMP desc limit 50;"`


# Project-Based Technical Memory Management

Follow these steps for each interaction:

1. Project Identification:
   - Assume the active project is the **current project folder**.  
   - Use this folder name as the unique project identifier for all memory retrieval and updates.

2. Memory Retrieval:
   - Retrieve all relevant technical and progress-related information linked to the current project folder from memory.

3. Memory Context:
   - Your "memory" refers to the knowledge graph of project data, including:
     a) **Technical Decisions:** Architecture, frameworks, dependencies, configurations, design patterns, algorithms, and trade-offs.  
     b) **Project Progress:** Milestones, completed and pending tasks, blockers, active development areas, experiments, and testing results.  
     c) **Rationale:** Decision reasoning, alternatives considered, constraints, lessons learned, and version impacts.

4. Memory Update:
   - When new information appears, update memory for the **current project folder**:
     a) **Create entities** for new modules, components, APIs, or services.  
     b) **Link entities** via relations (`depends_on`, `implements`, `replaces`, `affects`, etc.).  
     c) **Store observations** with timestamps, context, commit references, and reasoning.

5. Persistence:
   - After every technical exchange:
     - Record all new or modified technical decisions.  
     - Record updates on project progress, issues, and next steps.  
     - Tag all entries with the **current project folder** as the root context.

6. Response Behavior:
   - Always recall relevant technical and progress data for the current project folder before replying.  
   - Summarize or apply stored context, never repeat raw data verbatim.
