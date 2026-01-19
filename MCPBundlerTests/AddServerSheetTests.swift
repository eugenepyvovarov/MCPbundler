import XCTest
import MCP
@testable import MCPBundler

final class AddServerSheetTests: XCTestCase {
    func testPreflightAddsOAuthHeaderWhenMissing() throws {
        let outcome = ServerConnectionTestGuidance.preflight(kind: .remote_http_sse,
                                                             signInMode: .automaticOAuth,
                                                             headers: [],
                                                             useManualOAuthClient: false,
                                                             manualClientId: "")

        XCTAssertEqual(outcome?.oauthActionMessage, "Authentication required. Sign in to continue.")
        XCTAssertEqual(outcome?.healthStatus, .unhealthy)
        XCTAssertTrue(outcome?.headers.contains { $0.valueSource == .oauthAccessToken } ?? false)
    }

    func testPreflightPromptsManualCredentialsWhenClientIdMissing() throws {
        let headers = [
            HeaderBinding(server: nil,
                          header: "Authorization",
                          valueSource: .oauthAccessToken,
                          plainValue: nil,
                          keychainRef: nil)
        ]

        let outcome = ServerConnectionTestGuidance.preflight(kind: .remote_http_sse,
                                                             signInMode: .automaticOAuth,
                                                             headers: headers,
                                                             useManualOAuthClient: true,
                                                             manualClientId: "")

        XCTAssertEqual(outcome?.oauthActionMessage,
                       "Manual OAuth client credentials required. Enter client ID/secret before continuing.")
        XCTAssertEqual(outcome?.healthStatus, .unhealthy)
        XCTAssertTrue(outcome?.headers.contains { $0.valueSource == .oauthAccessToken } ?? false)
    }

    func testErrorGuidanceAddsOAuthHeaderOnAuthenticationError() throws {
        let outcome = ServerConnectionTestGuidance.guidanceAfterError(kind: .remote_http_sse,
                                                                      signInMode: .automaticOAuth,
                                                                      headers: [],
                                                                      error: MCPError.internalError("Authentication required"))

        XCTAssertEqual(outcome?.oauthActionMessage, "Authentication required. Sign in to continue.")
        XCTAssertTrue(outcome?.headers.contains { $0.valueSource == .oauthAccessToken } ?? false)
    }

    func testErrorGuidanceShowsEndpointHintWhenEndpointMissing() throws {
        let outcome = ServerConnectionTestGuidance.guidanceAfterError(
            kind: .remote_http_sse,
            signInMode: .automaticOAuth,
            headers: [],
            error: MCPError.transportError(URLError(.fileDoesNotExist))
        )

        XCTAssertEqual(outcome?.oauthActionMessage,
                       "Endpoint not found. Sign in first so Jura can expose its capability routes.")
    }

    func testNonRemoteServersDoNotReceiveGuidance() throws {
        let preflight = ServerConnectionTestGuidance.preflight(kind: .local_stdio,
                                                               signInMode: .automaticOAuth,
                                                               headers: [],
                                                               useManualOAuthClient: false,
                                                               manualClientId: "")
        XCTAssertNil(preflight)

        let guidance = ServerConnectionTestGuidance.guidanceAfterError(kind: .local_stdio,
                                                                       signInMode: .automaticOAuth,
                                                                       headers: [],
                                                                       error: MCPError.internalError("Authentication required"))
        XCTAssertNil(guidance)
    }
}

