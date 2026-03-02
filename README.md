<h1 align="center">MCP Bundler (macOS)</h1>

MCP Bundler is a macOS SwiftUI app for managing and running Agent Skills and Model Context Protocol (MCP)
servers, with a headless stdio mode for CLI and automation workflows. The codebase targets
the MCP lifecycle spec baseline dated 2025-06-18.



## Status

I decided to move the project from Paid software to open source thanks to <a href="https://bags.fm/">Bags platform</a>
I need some time to prepare the code for open sourcing it and for allowing to download builds straight from the site and remove license gate.
Bear with me, I need some hours for this.

Until then you can download app here: <a href="https://mcp-bundler.com/downloads/MCPBundler-latest.zip">TEMP DOWNLOAD LINK</a>

## Features

- Manage local MCP servers and remote endpoints from a native macOS UI.
- Headless stdio runner for scripting and tool integrations.
- Skill marketplace sources with curated defaults.
- OAuth flows and remote auth support (work in progress).

## Screenshots

![MCP Servers view](docs/screenshots/1.png)
_Servers list with folders, health status, and quick actions._

![Skills library](docs/screenshots/2.png)
_Skills library with folders and per-location toggles._

![Project settings](docs/screenshots/3.png)
_Project settings for skill sync locations, marketplaces, and optimizations._

![Project logs](docs/screenshots/4.png)
_Project logs with auto-refresh controls and pagination._

![Skills marketplace](docs/screenshots/5.png)
_Skills marketplace browser with categories and install actions._

## Requirements

- macOS
- Xcode (latest stable)

## Contributing

PRs should describe changes, list tests run, and link relevant spec sections or issues.

## Code of Conduct

Be respectful and constructive. By participating, you agree to follow the GitHub Community Guidelines.

## Security

Please use GitHub Security Advisories for sensitive disclosures. Do not file public issues for security
vulnerabilities.

## Support

Open a GitHub issue with clear steps to reproduce, logs, and screenshots where relevant.

## License

Apache-2.0. See LICENSE.
