import XCTest
import MCP
import SwiftData
@testable import MCPBundler

@MainActor
final class DataIntegrityServiceTests: XCTestCase {
    func test_repairRenamesDuplicateAliases() throws {
        let (context, storeURL, cleanup) = try makePersistentContext()
        defer { cleanup() }

        let project = Project(name: "Alpha", isActive: true)
        context.insert(project)
        let serverA = Server(project: project, alias: "dup", kind: .local_stdio)
        let serverB = Server(project: project, alias: "dup", kind: .local_stdio)
        context.insert(serverA)
        context.insert(serverB)
        project.servers.append(serverA)
        project.servers.append(serverB)
        try context.save()

        let service = DataIntegrityService(context: context)
        let report = service.scan()
        XCTAssertEqual(report.summary.duplicateAliasCount, 1)

        _ = service.repair(report: report, storeURL: storeURL)

        let aliases = project.servers.map { $0.alias.lowercased() }
        XCTAssertEqual(Set(aliases).count, 2)
        XCTAssertTrue(aliases.contains("dup"))
        XCTAssertTrue(aliases.contains(where: { $0.hasSuffix("-2") }))
    }

    func test_repairDeletesOrphanEnvVars() throws {
        let (context, storeURL, cleanup) = try makePersistentContext()
        defer { cleanup() }

        let project = Project(name: "Env", isActive: true)
        context.insert(project)
        let env = EnvVar(project: project, key: "FOO", valueSource: .plain, plainValue: "bar")
        context.insert(env)
        project.envVars.append(env)
        try context.save()

        let service = DataIntegrityService(context: context)
        let report = service.scan()
        XCTAssertEqual(report.summary.orphanEnvVarCount, 1)

        _ = service.repair(report: report, storeURL: storeURL)

        XCTAssertTrue(project.envVars.isEmpty)
    }

    func test_repairPrunesDuplicateCaches() throws {
        let (context, storeURL, cleanup) = try makePersistentContext()
        defer { cleanup() }

        let project = Project(name: "Cache", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "cached", kind: .remote_http_sse)
        context.insert(server)
        project.servers.append(server)

        let caps = MCPCapabilities(serverName: "Mock", serverDescription: nil,
                                   tools: [MCPTool(name: "hello", description: "hi", inputSchema: nil)],
                                   resources: nil, prompts: nil)
        let data = try JSONEncoder().encode(caps)
        let older = CapabilityCache(server: server, payload: data, generatedAt: Date(timeIntervalSinceNow: -3600))
        let newer = CapabilityCache(server: server, payload: data, generatedAt: Date())
        server.capabilityCaches.append(older)
        server.capabilityCaches.append(newer)
        try context.save()

        let service = DataIntegrityService(context: context)
        let report = service.scan()
        XCTAssertEqual(report.summary.duplicateCacheCount, 1)

        _ = service.repair(report: report, storeURL: storeURL)

        XCTAssertEqual(server.capabilityCaches.count, 1)
        XCTAssertEqual(server.capabilityCaches.first?.generatedAt, newer.generatedAt)
    }

    func test_repairDisablesServerWithInvalidCache() throws {
        let (context, storeURL, cleanup) = try makePersistentContext()
        defer { cleanup() }

        let project = Project(name: "Invalid", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "bad", kind: .remote_http_sse)
        context.insert(server)
        project.servers.append(server)

        let invalidPayload = Data("invalid".utf8)
        server.capabilityCaches.append(CapabilityCache(server: server, payload: invalidPayload, generatedAt: Date()))
        try context.save()

        let service = DataIntegrityService(context: context)
        let report = service.scan()
        XCTAssertEqual(report.summary.invalidCacheCount, 1)

        _ = service.repair(report: report, storeURL: storeURL)

        XCTAssertFalse(server.isEnabled)
        XCTAssertTrue(server.capabilityCaches.isEmpty)
    }

    func test_snapshotDedupesDuplicateToolNames() async throws {
        let server = Server(project: nil, alias: "dup", kind: .local_stdio)
        let tools = [
            MCPTool(name: "echo", description: "first", inputSchema: nil),
            MCPTool(name: "echo", description: "second", inputSchema: nil)
        ]
        let caps = MCPCapabilities(serverName: "Dup", serverDescription: nil,
                                   tools: tools,
                                   resources: nil,
                                   prompts: nil)
        let aggregator = BundlerAggregator(serverCapabilities: [(server, caps)])
        let snapshot = try await aggregator.buildSnapshot()

        XCTAssertEqual(snapshot.tools.count, 1)
        XCTAssertEqual(snapshot.tools.first?.description, "second")
    }

    private func makePersistentContext() throws -> (ModelContext, URL, () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let storeURL = base.appendingPathComponent("test.sqlite")
        let container = try TestModelContainerFactory.makePersistentContainer(at: storeURL)
        let context = ModelContext(container)
        let cleanup: () -> Void = {
            _ = try? FileManager.default.removeItem(at: base)
        }
        return (context, storeURL, cleanup)
    }
}
