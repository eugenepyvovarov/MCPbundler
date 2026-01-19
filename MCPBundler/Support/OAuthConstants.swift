//
//  OAuthConstants.swift
//  MCP Bundler
//
//  Shared constants for OAuth integrations.
//

import Foundation

enum OAuthConstants {
    /// MCP basic authorization spec revision supported by the app.
    static let mcpProtocolVersion = "2025-06-18"

    /// Fixed client origin used for all outbound MCP HTTP traffic.
    static let clientOrigin = "https://mcp-bundler.maketry.xyz"
}
