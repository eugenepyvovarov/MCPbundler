# Skills System

## Overview
Skills let MCP Bundler ship reusable instructions and supporting files as MCP tools. Skills are managed once in a global library, then enabled per project.

## Library and Formats
- Skills live under `~/Library/Application Support/Lifeisgoodlabs.MCP-Bundler/Skills`.
- Supported formats:
  - A folder containing `SKILL.md`.
  - A `.zip` or `.skill` archive with `SKILL.md` at the root or inside a single top-level folder.
- `SKILL.md` includes YAML front matter (name, description, optional metadata) plus the instruction body.

## Adding and Managing Skills
- Import skills from a folder or archive in the Skills tab.
- Use "Add Skill from URL" to install from a GitHub folder containing `SKILL.md` (preview shown before install).
- Install from a marketplace entry to add curated skills quickly.
- Edit display names or descriptions without changing the underlying slug.
- Delete skills to remove them from the library and all projects.

### Organizing Skills
- Skill folders are virtual groups inside MCP Bundler.
- They help organize large libraries without changing files on disk.
- You can create, rename, collapse, and move skills between folders at any time.

## Tool Exposure and Resources
- Skills are exposed under the alias `mcpbundler_skills`.
- Tool names are namespaced as `mcpbundler_skills__{slug}`.
- Each skill can include resource files that clients can read through MCP Bundler.
- A compatibility tool, `fetch_resource`, is available for clients that do not support MCP `resources/read`.

## Native Sync and Visibility
### Adding Skill Folder Locations
- MCP Bundler can sync skills into multiple client folders (Codex, Claude, VS Code, etc.).
- Add or remove locations in the global Skills settings.
- Each location can be enabled or disabled independently.

### Sync Between Different Skills Folders
- Enable a skill for one or more locations to export it there.
- MCP Bundler keeps exports in sync and removes them when you disable a location.
- If a skill already exists in a location, MCP Bundler will show a conflict prompt so you can keep the existing copy or import it into the library.

### Hiding Skills for Native Clients
- The "Hide Skills for clients with native skills support" toggle keeps skills out of tool lists for native clients while still allowing them in other clients.

## Marketplaces
### Skills Marketplaces
- Add GitHub-based marketplaces in the global Skills settings.
- Each marketplace is a repository that publishes a skills manifest.

### Browse and Install UX
- Open the Skills Marketplace sheet to browse available skills.
- Choose a source, filter by category or keywords, preview entries, and install.
- Installed skills appear in your library and can be enabled per project.

## Instruction Copy
The bundled response includes a notice and usage block. Keep this text in sync with `SkillsInstructionCopy` in `MCPBundler/Services/BundledServer.swift`.

Preamble template:

```
[Skill Notice] The following guidance is authored by the "{displayName}" skill. Load only the files it references (via MCP resources or fetch_resource if your client lacks resources/read) and apply the instructions with your own tools.
```

Usage block:

```
This response contains expert instructions:
1. Read the full guidance before acting.
2. Understand your original task, any allowed-tools hints, and the resource list.
3. Apply the workflow with your own judgment - skills don't execute steps for you.
4. Access referenced files via MCP resources/list + resources/read. If your client lacks MCP resource support, call fetch_resource with the provided URI.
5. Respect any constraints or best practices the skill specifies.
```
