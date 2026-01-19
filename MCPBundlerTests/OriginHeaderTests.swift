import XCTest
@testable import MCPBundler
import MCP

@MainActor
final class OriginHeaderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        InMemoryHTTPSSEServer.register()
    }
    override class func tearDown() {
        InMemoryHTTPSSEServer.unregister()
        super.tearDown()
    }

    func test_originHeaderPresentOnGETAndPOST() async throws {
        InMemoryHTTPSSEServer.reset()
        InMemoryHTTPSSEServer.config.emitEndpointAfter = 0
        InMemoryHTTPSSEServer.config.initialBasePostStatus = nil

        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let project = Project(name: "P", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "jira", kind: .remote_http_sse)
        server.baseURL = InMemoryHTTPSSEServer.config.baseURL.absoluteString
        context.insert(server)
        try context.save()

        let provider = UpstreamProvider(server: server,
                                        provider: SDKRemoteHTTPProvider()) { _,_,_ in }
        let client = try await provider.ensureClient()
        // trigger a POST over session URL
        _ = try await client.listTools()

        let expectedOrigin = OAuthConstants.clientOrigin
        XCTAssertEqual(InMemoryHTTPSSEServer.lastGETHeaders["Origin"], expectedOrigin)
        XCTAssertEqual(InMemoryHTTPSSEServer.lastPOSTHeaders["Origin"], expectedOrigin)

        await client.disconnect()
        await provider.disconnect(reason: .manual)
    }
}
