import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class BundledServerHostFacadeTests: XCTestCase {
    func testHostUsesInjectedManagerWithoutWarmup() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "HostTest", isActive: true)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .remote_http_sse)
        server.baseURL = "https://alpha.example"
        project.servers.append(server)
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: server)
        try context.save()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        let snapshot = try ProjectSnapshotCache.snapshot(for: project)

        let stubManager = BundledServerManager(providerFactory: { _, _, _ in
            StubProvider()
        }, warmUpHandler: { _ in })

        let (factory, _, teardown) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: stubManager, transportFactory: factory)
        host.setPersistenceContext(context)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: StaticCapabilitiesProvider(alias: "alpha")
        ]

        do {
            _ = try await host.start(project: project, snapshot: snapshot, providers: providers)
        } catch {
            XCTFail("start failed: \(error)")
        }

        await host.stop()
        await teardown()
    }
}

private struct StaticCapabilitiesProvider: CapabilitiesProvider {
    let alias: String

    func fetchCapabilities(for server: MCPBundler.Server) async throws -> MCPCapabilities {
        TestCapabilitiesBuilder.makeDefaultCapabilities(for: server)
    }
}

@MainActor
private final class StubProvider: UpstreamProviding {
    var alias: String { "stub" }
    var shouldKeepConnectionWarm: Bool { false }
    var serverIdentifier: PersistentIdentifier? { nil }

    func update(server: MCPBundler.Server, provider: any CapabilitiesProvider) async -> Bool { false }
    func synchronize(server: MCPBundler.Server, provider: any CapabilitiesProvider) {}
    func ensureClient() async throws -> MCP.Client { Client(name: "Stub", version: "1.0") }
    func ensureWarmConnection() async throws {}
    func resetAfterFailure() async {}
    func disconnect(reason: UpstreamDisconnectReason) async {}
}
