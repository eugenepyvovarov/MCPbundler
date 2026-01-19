//
//  CapabilitiesProvider.swift
//  MCP Bundler
//
//  Protocol for providing MCP server capabilities
//

import Foundation
import MCP
import SwiftData

// MARK: - Data Models

struct MCPCapabilities: Codable, Sendable {
    var serverName: String?
    var serverDescription: String?
    var tools: [MCPTool]
    var resources: [MCPResource]? // optional
    var prompts: [MCPPrompt]? // optional
}

struct MCPTool: Codable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var title: String?
    var description: String?
    var inputSchema: Value?
    var annotations: Tool.Annotations?

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case annotations
    }

    init(name: String,
         title: String? = nil,
         description: String? = nil,
         inputSchema: Value? = nil,
         annotations: Tool.Annotations? = nil) {
        self.name = name
        self.title = title ?? annotations?.title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

struct MCPResource: Codable, Sendable {
    var name: String
    var uri: String
    var description: String?
}

struct MCPPrompt: Codable, Sendable {
    var name: String
    var description: String?
}

// MARK: - Protocol

protocol CapabilitiesProvider {
    @MainActor
    func fetchCapabilities(for server: Server) async throws -> MCPCapabilities
}

enum CapabilityError: Error {
    case invalidConfiguration
    case executionFailed(String)
}
