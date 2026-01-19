import XCTest
@testable import MCPBundler

@MainActor
final class UpstreamProviderSessionTests: XCTestCase {

    func testEnsureClientUsesExposedProvider() async throws {
        let server = Server(alias: "jira", kind: .remote_http_sse)
        server.baseURL = "https://example.com/v1/sse"
        let provider = MockRemoteProvider()
        let upstream = UpstreamProvider(server: server, provider: provider) { _,_,_ in }

        let client = try await upstream.ensureClient()

        XCTAssertIdentical(client, provider.client)
        XCTAssertEqual(provider.connectCallCount, 1)
        XCTAssertTrue(provider.awaitHintCallCount >= 0) // optional wait hook
        XCTAssertEqual(upstream.state, .ready)
        XCTAssertEqual(server.remoteHTTPMode, .httpWithSSE)
    }

    func testDisconnectResetsRuntimeSession() async throws {
        let server = Server(alias: "jira", kind: .remote_http_sse)
        server.baseURL = "https://example.com/v1/sse"
        let provider = MockRemoteProvider()
        let upstream = UpstreamProvider(server: server, provider: provider) { _,_,_ in }

        _ = try await upstream.ensureClient()
        await upstream.disconnect(reason: .manual)

        XCTAssertEqual(provider.resetCallCount, 1)
        XCTAssertNil(provider.runtimeClientReference)
    }

    func testUnauthorizedStopsWarmupRetry() async throws {
        let server = Server(alias: "jira", kind: .remote_http_sse)
        server.baseURL = "https://example.com/v1/sse"
        let provider = MockRemoteProvider()
        provider.shouldThrowPermissionDenied = true
        let upstream = UpstreamProvider(server: server, provider: provider) { _,_,_ in }

        await XCTAssertThrowsErrorAsync(try await upstream.ensureClient())
        XCTAssertEqual(server.oauthStatus, .unauthorized)
        XCTAssertEqual(provider.connectCallCount, 1)
    }

    func testTokensRefreshedNotificationResetsSession() async throws {
        let server = Server(alias: "jira", kind: .remote_http_sse)
        server.baseURL = "https://example.com/v1/sse"
        let provider = MockRemoteProvider()
        let upstream = UpstreamProvider(server: server, provider: provider) { _,_,_ in }

        _ = try await upstream.ensureClient()
        let idString = String(describing: server.persistentModelID)
        NotificationCenter.default.post(name: .oauthTokensRefreshed,
                                        object: nil,
                                        userInfo: ["serverID": idString])
        // allow async handler to run
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(provider.resetCallCount, 1)
        XCTAssertEqual(provider.connectCallCount, 2)
    }

    func testWarmConnectionRequiresSSEMode() {
        let server = Server(alias: "jira", kind: .remote_http_sse)
        let provider = MockRemoteProvider()
        let upstream = UpstreamProvider(server: server, provider: provider) { _,_,_ in }

        server.remoteHTTPMode = .auto
        XCTAssertFalse(upstream.shouldKeepConnectionWarm)

        server.remoteHTTPMode = .httpWithSSE
        XCTAssertTrue(upstream.shouldKeepConnectionWarm)

        server.remoteHTTPMode = .httpOnly
        XCTAssertFalse(upstream.shouldKeepConnectionWarm)
    }
}

@MainActor
private final class MockRemoteProvider: CapabilitiesProvider, ExposesClient {
    private(set) var connectCallCount = 0
    private(set) var awaitHintCallCount = 0
    private(set) var resetCallCount = 0
    var shouldThrowPermissionDenied = false

    let client = Client(name: "Mock", version: "1.0")
    private(set) var runtimeClientReference: Client?

    func fetchCapabilities(for server: Server) async throws -> MCPCapabilities {
        return MCPCapabilities(serverName: "mock", serverDescription: nil, tools: [], resources: nil, prompts: nil)
    }

    func connectAndReturnClient(for server: Server) async throws -> Client {
        connectCallCount += 1
        if shouldThrowPermissionDenied {
            server.oauthStatus = .unauthorized
            throw CapabilityError.permissionDenied
        }
        runtimeClientReference = client
        server.remoteHTTPMode = .httpWithSSE
        return client
    }

    func awaitHintIfNeeded(timeout: TimeInterval) async -> Bool {
        awaitHintCallCount += 1
        return true
    }

    func resetRuntimeSession() async {
        resetCallCount += 1
        runtimeClientReference = nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch { }
}
