import XCTest
@testable import MCPBundler
import MCP

@MainActor
final class OAuthHTTPSSERemoteIntegrationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        InMemoryHTTPSSEServer.register()
    }
    override class func tearDown() {
        InMemoryHTTPSSEServer.unregister()
        super.tearDown()
    }

    func test_authorizationHeaderFlowsOnGETAndPOST() async throws {
        InMemoryHTTPSSEServer.reset()
        InMemoryHTTPSSEServer.config.emitEndpointAfter = 0

        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let project = Project(name: "Auth", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "remote", kind: .remote_http_sse)
        server.baseURL = InMemoryHTTPSSEServer.config.baseURL.absoluteString
        // Simulate OAuth header binding already provisioned
        server.headers.append(HeaderBinding(server: server, header: "Authorization", valueSource: .plain, plainValue: "Bearer TEST"))
        context.insert(server)
        try context.save()

        let provider = UpstreamProvider(server: server,
                                        provider: SDKRemoteHTTPProvider()) { _,_,_ in }
        let client = try await provider.ensureClient()
        _ = try await client.listTools()

        XCTAssertEqual(InMemoryHTTPSSEServer.lastGETHeaders["Authorization"], "Bearer TEST")
        XCTAssertEqual(InMemoryHTTPSSEServer.lastPOSTHeaders["Authorization"], "Bearer TEST")

        await client.disconnect()
        await provider.disconnect(reason: .manual)
    }
}

