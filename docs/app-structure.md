# App Structure

## Overview
MCP Bundler organizes your work into projects. Each project groups MCP servers, skill selections, and settings. The active project is the one used by headless mode.

## Main Workspace
- Sidebar: shows projects and lets you add, rename, delete, or quickly switch the active project.
- Detail area: switches between Servers, Skills, and Settings for the selected project.
- Import flows: available from the Servers area to bring in definitions from files, JSON, or install links.

## Projects and Servers
- A project is a self-contained workspace for a set of MCP servers.
- Only one project is active at a time; you can change it quickly from the sidebar.
- Servers can be local (STDIO) or remote (HTTP/SSE).
- You can enable or disable servers without deleting them.

### Virtual Server Folders
- Provider folders group servers inside the app.
- They are virtual and do not change files on disk.
- Folders help keep larger projects organized and can be renamed or collapsed.

## Skills
- Skills are managed globally but enabled per project.
- Each project chooses which skills are available to clients.

## Data and Storage
- All data is stored locally on your Mac.
- The app can rebuild cached data when you edit a project or import new servers.
- Advanced: you can move the store location using the `MCP_BUNDLER_STORE_URL` environment variable.
