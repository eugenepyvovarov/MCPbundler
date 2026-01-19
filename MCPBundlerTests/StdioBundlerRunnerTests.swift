import XCTest
import SwiftData
import MCP
@testable import MCPBundler

private typealias BundlerServer = MCPBundler.Server

@MainActor
final class StdioBundlerRunnerTests: XCTestCase {
    func testReloadSkipsWhenProjectMismatch() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let activeProject = Project(name: "Active", isActive: true)
        let server = makeServer(alias: "alpha", project: activeProject)
        activeProject.servers.append(server)

        let otherProject = Project(name: "Other", isActive: false)

        context.insert(activeProject)
        context.insert(otherProject)
        try context.save()

        try await ProjectSnapshotCache.rebuildSnapshot(for: activeProject)

        let host = MockBundledServerHost()
        let runner = StdioBundlerRunner(container: container, host: host) { _ in
            StaticCapabilitiesProvider()
        }

        _ = try await runner.start()

        await runner.reload(projectID: otherProject.persistentModelID, serverIDs: nil)

        XCTAssertEqual(host.reloadCalls.count, 0, "Reload should not be invoked for mismatched project ID")
    }

    func testReloadPassesTargetedServerIDs() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Scoped", isActive: true)
        let serverA = makeServer(alias: "alpha", project: project)
        let serverB = makeServer(alias: "beta", project: project)
        project.servers.append(contentsOf: [serverA, serverB])

        context.insert(project)
        try context.save()

        try await ProjectSnapshotCache.rebuildSnapshot(for: project)

        let host = MockBundledServerHost()
        let runner = StdioBundlerRunner(container: container, host: host) { _ in
            StaticCapabilitiesProvider()
        }

        _ = try await runner.start()

        let targeted = Set([serverA.persistentModelID])
        await runner.reload(projectID: project.persistentModelID, serverIDs: targeted)

        XCTAssertEqual(host.reloadCalls.count, 1)
        let call = try XCTUnwrap(host.reloadCalls.first)
        XCTAssertEqual(call.serverIDs, targeted)
    }

    func testStartFailsWhenSnapshotDecodeFails() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Flaky", isActive: true)
        let server = makeServer(alias: "alpha", project: project)
        project.servers.append(server)

        context.insert(project)
        try context.save()

        try await ProjectSnapshotCache.rebuildSnapshot(for: project)

        project.cachedSnapshot = Data("not-a-valid-snapshot".utf8)
        project.cachedSnapshotVersion = ProjectSnapshotCache.currentVersion
        project.cachedSnapshotGeneratedAt = Date()
        try context.save()

        let host = MockBundledServerHost()
        let runner = StdioBundlerRunner(container: container, host: host) { _ in
            StaticCapabilitiesProvider()
        }

        do {
            _ = try await runner.start()
            XCTFail("Expected missingSnapshot error")
        } catch let error as StdioBundlerRunner.RunnerError {
            XCTAssertEqual(error, .missingSnapshot)
        } catch {
            XCTFail("Expected missingSnapshot, got: \(error)")
        }

        XCTAssertFalse(host.startCalled)
    }

    // MARK: - Helpers

    private func makeServer(alias: String, project: Project) -> BundlerServer {
        let server = BundlerServer(project: project, alias: alias, kind: .local_stdio)
        let caps = MCPCapabilities(serverName: alias.capitalized,
                                   serverDescription: nil,
                                   tools: [],
                                   resources: nil,
                                   prompts: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try! encoder.encode(caps)
        let cache = CapabilityCache(server: server, payload: payload, generatedAt: Date())
        server.capabilityCaches.append(cache)
        return server
    }
}

// MARK: - Test Doubles

@MainActor
private final class MockBundledServerHost: BundledServerHosting {
    struct ReloadCall {
        let project: Project
        let snapshot: BundlerAggregator.Snapshot
        let serverIDs: Set<PersistentIdentifier>?
    }

    private(set) var reloadCalls: [ReloadCall] = []
    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var persistenceContext: ModelContext?

    func start(project: Project,
               snapshot: BundlerAggregator.Snapshot,
               providers: [BundlerServer: any CapabilitiesProvider]) async throws -> StdioTransport? {
        startCalled = true
        return nil
    }

    func waitForTermination() async throws {}

    func stop() async {
        stopCalled = true
    }

    func reload(project: Project,
                snapshot: BundlerAggregator.Snapshot,
                providers: [BundlerServer: any CapabilitiesProvider],
                serverIDs: Set<PersistentIdentifier>?) async throws {
        reloadCalls.append(ReloadCall(project: project, snapshot: snapshot, serverIDs: serverIDs))
    }

    func setPersistenceContext(_ context: ModelContext?) {
        persistenceContext = context
    }
}

private struct StaticCapabilitiesProvider: CapabilitiesProvider {
    func fetchCapabilities(for server: BundlerServer) async throws -> MCPCapabilities {
        MCPCapabilities(serverName: server.alias,
                        serverDescription: nil,
                        tools: [],
                        resources: nil,
                        prompts: nil)
    }
}
