import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class OAuthServiceParsingTests: XCTestCase {
    func testParsesWWWAuthenticateHeader() {
        let raw = "Bearer realm=\"Example\", resource=\"https://api.example.com\", resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource\", scope=\"read write\""
        let header = WWWAuthenticateHeader.parse(raw)

        XCTAssertNotNil(header)
        XCTAssertEqual(header?.scheme, "Bearer")
        XCTAssertEqual(header?.resource?.absoluteString, "https://api.example.com")
        XCTAssertEqual(header?.resourceMetadata?.absoluteString, "https://api.example.com/.well-known/oauth-protected-resource")
        XCTAssertEqual(header?.scopes, ["read", "write"])
    }

    func testPerformActionWithFreshTokensWithoutStoredStateReturnsNil() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let project = Project(name: "Tokenless", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "Remote", kind: .remote_http_sse)
        context.insert(server)
        try context.save()

        let expectation = expectation(description: "Completion invoked")
        OAuthService.shared.performActionWithFreshTokens(server: server) { token in
            XCTAssertNil(token)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
        XCTAssertEqual(server.oauthStatus, .unauthorized)
    }
}
