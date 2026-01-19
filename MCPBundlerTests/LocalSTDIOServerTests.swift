//
//  LocalSTDIOServerTests.swift
//  MCP BundlerTests
//
//  Automated tests for local STDIO MCP server functionality
//

import XCTest
import Foundation
import SwiftData
import MCP
@testable import MCPBundler

private typealias BundlerServer = MCPBundler.Server

@MainActor
final class LocalSTDIOServerTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        // Create in-memory container for testing
        container = try TestModelContainerFactory.makeInMemoryContainer()
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    // MARK: - Basic Configuration Tests

    func testLocalSTDIOServerCreation() async throws {
        let project = Project(name: "Test Project")
        context.insert(project)

        let server = BundlerServer(project: project, alias: "test-server", kind: .local_stdio)
        server.execPath = "/bin/echo"
        server.args = ["Hello MCP"]
        context.insert(server)

        try context.save()

        // Verify server properties
        XCTAssertEqual(server.kind, .local_stdio)
        XCTAssertEqual(server.alias, "test-server")
        XCTAssertEqual(server.execPath, "/bin/echo")
        XCTAssertEqual(server.args, ["Hello MCP"])
        XCTAssertEqual(server.project, project)
    }

    func testEnvironmentVariableConfiguration() async throws {
        let project = Project(name: "Test Project")
        context.insert(project)

        // Add project-level env vars
        let projectEnv = EnvVar(project: project, key: "PROJECT_VAR", valueSource: .plain, plainValue: "project-value")
        context.insert(projectEnv)

        let server = BundlerServer(project: project, alias: "test-server", kind: .local_stdio)
        server.execPath = "/usr/bin/env"

        // Add server-level env vars (should override project-level)
        let serverEnv = EnvVar(server: server, key: "SERVER_VAR", valueSource: .plain, plainValue: "server-value")
        let overrideEnv = EnvVar(server: server, key: "PROJECT_VAR", valueSource: .plain, plainValue: "overridden-value")
        context.insert(serverEnv)
        context.insert(overrideEnv)

        try context.save()

        // Test environment building
        let env = buildEnvironment(for: server)

        XCTAssertEqual(env["PROJECT_VAR"], "overridden-value")
        XCTAssertEqual(env["SERVER_VAR"], "server-value")
    }

    // MARK: - Firecrawl MCP Server Tests

    func testFirecrawlMCPServerConfiguration() async throws {
        let project = Project(name: "Test Project")
        context.insert(project)

        let server = BundlerServer(project: project, alias: "firecrawl", kind: .local_stdio)
        server.execPath = "/usr/bin/npx"
        server.args = ["-y", "firecrawl-mcp"]

        // Add required environment variable
        let apiKeyEnv = EnvVar(server: server, key: "FIRECRAWL_API_KEY", valueSource: .plain, plainValue: "fc-test-key")
        context.insert(apiKeyEnv)

        try context.save()

        // Verify configuration
        XCTAssertEqual(server.alias, "firecrawl")
        XCTAssertEqual(server.kind, .local_stdio)
        XCTAssertEqual(server.execPath, "/usr/bin/npx")
        XCTAssertEqual(server.args, ["-y", "firecrawl-mcp"])
        XCTAssertEqual(server.envOverrides.count, 1)
        XCTAssertEqual(server.envOverrides.first?.key, "FIRECRAWL_API_KEY")
        XCTAssertEqual(server.envOverrides.first?.plainValue, "fc-test-key")
    }

    func testFirecrawlMCPServerWithKeychainSecret() async throws {
        let project = Project(name: "Test Project")
        context.insert(project)

        let server = BundlerServer(project: project, alias: "firecrawl", kind: .local_stdio)
        server.execPath = "/usr/bin/npx"
        server.args = ["-y", "firecrawl-mcp"]

        // Add environment variable with keychain reference
        let apiKeyEnv = EnvVar(
            server: server,
            key: "FIRECRAWL_API_KEY",
            valueSource: .keychainRef,
            keychainRef: "firecrawl:api-key"
        )
        context.insert(apiKeyEnv)

        try context.save()

        // Test keychain reference parsing
        let (service, account) = parseKeychainRef(apiKeyEnv.keychainRef!)
        XCTAssertEqual(service, "firecrawl")
        XCTAssertEqual(account, "api-key")
    }

    // MARK: - BundlerAggregator Tests

    func testBundlerAggregatorNamespacing() async throws {
        // Create mock capabilities
        let capabilities = MCPCapabilities(
            serverName: "Firecrawl",
            serverDescription: nil,
            tools: [
                MCPTool(name: "search", description: "Search tool", inputSchema: .object([:])),
                MCPTool(name: "scrape", description: "Scrape tool", inputSchema: .object([:]))
            ],
            resources: nil,
            prompts: nil
        )

        let server = BundlerServer(alias: "firecrawl", kind: .local_stdio)

        let aggregator = BundlerAggregator(serverCapabilities: [(server: server, capabilities: capabilities)])
        let snapshot = try await aggregator.buildSnapshot()

        // Verify namespacing
        XCTAssertEqual(snapshot.tools.count, 2)
        XCTAssertEqual(snapshot.tools[0].namespaced, "firecrawl__scrape")
        XCTAssertEqual(snapshot.tools[1].namespaced, "firecrawl__search")
        XCTAssertEqual(snapshot.tools[0].alias, "firecrawl")
        XCTAssertEqual(snapshot.tools[0].original, "scrape")

        // Verify reverse lookup
        XCTAssertEqual(snapshot.toolMap["firecrawl__search"]?.alias, "firecrawl")
        XCTAssertEqual(snapshot.toolMap["firecrawl__search"]?.original, "search")
    }

    func testBundlerAggregatorIncludeFiltering() async throws {
        let capabilities = MCPCapabilities(
            serverName: "Firecrawl",
            serverDescription: nil,
            tools: [
                MCPTool(name: "search", description: "Search tool", inputSchema: .object([:])),
                MCPTool(name: "scrape", description: "Scrape tool", inputSchema: .object([:])),
                MCPTool(name: "crawl", description: "Crawl tool", inputSchema: .object([:]))
            ],
            resources: nil,
            prompts: nil
        )

        let server = BundlerServer(alias: "firecrawl", kind: .local_stdio)
        server.includeTools = ["search", "scrape"]

        let aggregator = BundlerAggregator(serverCapabilities: [(server: server, capabilities: capabilities)])
        let snapshot = try await aggregator.buildSnapshot()

        // Only included tools should be present
        XCTAssertEqual(snapshot.tools.count, 2)
        let toolNames = snapshot.tools.map { $0.original }
        XCTAssertTrue(toolNames.contains("search"))
        XCTAssertTrue(toolNames.contains("scrape"))
        XCTAssertFalse(toolNames.contains("crawl"))
    }

    func testBundlerAggregatorDefaultFiltering() async throws {
        let capabilities = MCPCapabilities(
            serverName: "Firecrawl",
            serverDescription: nil,
            tools: [
                MCPTool(name: "search", description: "Search tool", inputSchema: .object([:])),
                MCPTool(name: "scrape", description: "Scrape tool", inputSchema: .object([:])),
                MCPTool(name: "crawl", description: "Crawl tool", inputSchema: .object([:]))
            ],
            resources: nil,
            prompts: nil
        )

        let server = BundlerServer(alias: "firecrawl", kind: .local_stdio)

        let aggregator = BundlerAggregator(serverCapabilities: [(server: server, capabilities: capabilities)])
        let snapshot = try await aggregator.buildSnapshot()

        // Without include filters all tools should be exposed
        XCTAssertEqual(snapshot.tools.count, 3)
        let toolNames = snapshot.tools.map { $0.original }
        XCTAssertTrue(toolNames.contains("search"))
        XCTAssertTrue(toolNames.contains("scrape"))
        XCTAssertTrue(toolNames.contains("crawl"))
    }

    func testSkillsCompatibilityToolIsNotNamespaced() async throws {
        let compatibility = MCPTool(name: SkillsCapabilitiesBuilder.compatibilityToolName,
                                    description: "Compatibility helper",
                                    inputSchema: .object([:]))
        let caps = MCPCapabilities(serverName: "Skills",
                                   serverDescription: nil,
                                   tools: [compatibility],
                                   resources: nil,
                                   prompts: nil)
        let server = BundlerServer(alias: SkillsCapabilitiesBuilder.alias, kind: .local_stdio)
        let aggregator = BundlerAggregator(serverCapabilities: [(server: server, capabilities: caps)])
        let snapshot = try await aggregator.buildSnapshot()
        let tool = try XCTUnwrap(snapshot.tools.first)
        XCTAssertEqual(tool.namespaced, SkillsCapabilitiesBuilder.compatibilityToolName)
        XCTAssertEqual(tool.alias, SkillsCapabilitiesBuilder.alias)
        XCTAssertEqual(snapshot.toolMap[SkillsCapabilitiesBuilder.compatibilityToolName]?.alias,
                       SkillsCapabilitiesBuilder.alias)
    }

    // MARK: - In-memory Integration Tests


    // MARK: - Helper Methods

    private func assertThrowsError<T: Error>(
        ofType expectedType: T.Type,
        errorHandler: (T) -> Void = { _ in },
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected to throw \(expectedType)")
        } catch let error as T {
            errorHandler(error)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private struct InlineCapabilitiesProvider: CapabilitiesProvider {
        let capabilities: MCPCapabilities

        func fetchCapabilities(for server: BundlerServer) async throws -> MCPCapabilities {
            capabilities
        }
    }

}
