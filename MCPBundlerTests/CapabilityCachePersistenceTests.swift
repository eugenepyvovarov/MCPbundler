import XCTest
@testable import MCPBundler

@MainActor
final class CapabilityCachePersistenceTests: XCTestCase {
    func test_latestDecodedCapabilitiesDecodesPayload() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let project = Project(name: "Cache", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "remote", kind: .remote_http_sse)
        context.insert(server)
        let caps = MCPCapabilities(serverName: "Mock", serverDescription: nil,
                                   tools: [MCPTool(name: "hello", description: "hi", inputSchema: nil)],
                                   resources: nil, prompts: nil)
        let data = try JSONEncoder().encode(caps)
        let cache = CapabilityCache(server: server, payload: data, generatedAt: Date())
        server.capabilityCaches.append(cache)
        try context.save()

        let decoded = server.latestDecodedCapabilities
        XCTAssertEqual(decoded?.tools?.first?.name, "hello")
    }
}

