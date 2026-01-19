import XCTest
import MCP
import SwiftData
import AppAuth
@testable import MCPBundler

@MainActor
final class OAuthIntegrationTests: XCTestCase {
    func testServerOAuthStatusDefaultsToUnauthorized() {
        let server = Server(alias: "remote", kind: .remote_http_sse)
        XCTAssertEqual(server.oauthStatus, .unauthorized)

        server.oauthStatus = .authorized
        XCTAssertEqual(server.oauthStatus, .authorized)
    }

    func testRetryPolicyRecognizesAuthenticationErrors() {
        let authError = MCPError.internalError("Authentication required")
        XCTAssertTrue(OAuthRetryPolicy.isAuthenticationError(authError))

        let transportError = MCPError.transportError(URLError(.userAuthenticationRequired))
        XCTAssertTrue(OAuthRetryPolicy.isAuthenticationError(transportError))

        let otherError = MCPError.internalError("Other failure")
        XCTAssertFalse(OAuthRetryPolicy.isAuthenticationError(otherError))
    }

    func testDiscoveryPersistsAuthorizationMetadata() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let project = Project(name: "Discovery", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "Remote", kind: .remote_http_sse)
        server.baseURL = "https://api.example.com"
        context.insert(server)
        try context.save()

        let protectedURL = URL(string: "https://api.example.com/.well-known/oauth-protected-resource")!
        let authorizationURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!

        OAuthMockURLProtocol.handlers = [
            protectedURL: { _ in
                let body: [String: Any] = [
                    "resource": "https://api.example.com",
                    "authorization_servers": ["https://auth.example.com"],
                    "scopes_supported": ["read", "write"],
                    "registration_endpoint": "https://auth.example.com/register"
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (200, ["Content-Type": "application/json"], data)
            },
            URL(string: "https://auth.example.com")!: { _ in
                // Simulate 404 so discovery falls back to well-known paths
                return (404, [:], nil)
            },
            authorizationURL: { _ in
                let body: [String: Any] = [
                    "authorization_endpoint": "https://auth.example.com/oauth2/authorize",
                    "token_endpoint": "https://auth.example.com/oauth2/token",
                    "registration_endpoint": "https://auth.example.com/register",
                    "scopes_supported": ["read", "write"],
                    "code_challenge_methods_supported": ["S256"]
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (200, ["Content-Type": "application/json"], data)
            }
        ]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OAuthService.shared.configure(urlSession: session)

        defer {
            OAuthService.shared.configure(urlSession: .shared)
            OAuthMockURLProtocol.handlers = [:]
        }

        await OAuthService.shared.runAuthDiscovery(
            server: server,
            wwwAuthenticate: "Bearer resource_metadata=\"\(protectedURL.absoluteString)\""
        )

        try context.save()

        guard let configurationModel = server.oauthConfiguration else {
            return XCTFail("OAuth configuration was not persisted")
        }
        XCTAssertEqual(configurationModel.resourceURI?.absoluteString, "https://api.example.com")
        XCTAssertEqual(configurationModel.scopes, ["read", "write"])
        XCTAssertEqual(configurationModel.registrationEndpoint?.absoluteString, "https://auth.example.com/register")
        XCTAssertEqual(configurationModel.authorizationEndpoint?.absoluteString, "https://auth.example.com/oauth2/authorize")
        XCTAssertEqual(configurationModel.tokenEndpoint?.absoluteString, "https://auth.example.com/oauth2/token")
        XCTAssertEqual(server.oauthStatus, .unauthorized)
    }

    func testTokenRefreshPersistsStateAndHeaders() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let project = Project(name: "Tokens", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "Remote", kind: .remote_http_sse)
        server.baseURL = "https://api.example.com"
        server.headers.append(HeaderBinding(server: server, header: "Authorization", valueSource: .oauthAccessToken))
        context.insert(server)
        try context.save()

        let authorizationEndpoint = URL(string: "https://auth.example.com/oauth2/authorize")!
        let tokenEndpoint = URL(string: "https://auth.example.com/oauth2/token")!
        let serviceConfiguration = OIDServiceConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint)
        let redirectURL = URL(string: "http://localhost:8734/oauth/callback")!
        let authorizationRequest = OIDAuthorizationRequest(configuration: serviceConfiguration,
                                                           clientId: "client-id",
                                                           scopes: ["read"],
                                                           redirectURL: redirectURL,
                                                           responseType: OIDResponseTypeCode,
                                                           additionalParameters: ["resource": "https://api.example.com"])
        let authParameters: [String: NSObject & NSCopying] = [
            "code": "authorization-code" as NSString,
            "state": authorizationRequest.state! as NSString
        ]
        let authorizationResponse = OIDAuthorizationResponse(request: authorizationRequest, parameters: authParameters)

        let tokenRequest = OIDTokenRequest(configuration: serviceConfiguration,
                                           grantType: OIDGrantTypeAuthorizationCode,
                                           authorizationCode: "authorization-code",
                                           redirectURL: redirectURL,
                                           clientID: "client-id",
                                           clientSecret: nil,
                                           scopes: nil,
                                           refreshToken: nil,
                                           codeVerifier: authorizationRequest.codeVerifier,
                                           additionalParameters: ["resource": "https://api.example.com"])
        let tokenParameters: [String: NSObject & NSCopying] = [
            "access_token": "access-token-123456" as NSString,
            "token_type": "Bearer" as NSString,
            "refresh_token": "refresh-token-abcdef" as NSString,
            "expires_in": NSNumber(value: 3600)
        ]
        let tokenResponse = OIDTokenResponse(request: tokenRequest, parameters: tokenParameters)
        let authState = OIDAuthState(authorizationResponse: authorizationResponse, tokenResponse: tokenResponse)

        let archived = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
        server.oauthState = OAuthState(server: server, serializedAuthState: archived, lastTokenRefresh: nil, isActive: true)

        let expectation = expectation(description: "Token refresh callback")
        OAuthService.shared.performActionWithFreshTokens(server: server) { token in
            XCTAssertEqual(token, "access-token-123456")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(server.oauthStatus, .authorized)
        XCTAssertNotNil(server.oauthState?.lastTokenRefresh)
        XCTAssertTrue(server.oauthState?.isActive ?? false)

        let headers = buildHeaders(for: server)
        XCTAssertEqual(headers["Authorization"], "Bearer access-token-123456")
    }

    func testOAuthDebugLoggerRespectsToggle() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let project = Project(name: "Logging", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "Remote", kind: .remote_http_sse)
        context.insert(server)
        try context.save()

        OAuthDebugLogger.log("hidden", category: "oauth.debug", server: server)
        XCTAssertTrue(project.logs.isEmpty)

        server.isOAuthDebugLoggingEnabled = true
        OAuthDebugLogger.log("visible", category: "oauth.debug", server: server, metadata: ["k": "v"])
        try context.save()

        XCTAssertEqual(project.logs.count, 1)
        XCTAssertEqual(project.logs.first?.message, "visible")
        XCTAssertEqual(project.logs.first?.category, "oauth.debug")
    }

    func testStripeAccountHeaderFromProviderMetadata() {
        let server = Server(alias: "Stripe", kind: .remote_http_sse)
        server.baseURL = "https://mcp.stripe.com"
        server.headers.append(HeaderBinding(server: server, header: "Authorization", valueSource: .plain, plainValue: "Bearer test-token"))
        let state = OAuthState(server: server)
        state.providerMetadata = ["stripe_account": "acct_123"]
        server.oauthState = state

        let headers = buildHeaders(for: server)
        XCTAssertEqual(headers["Stripe-Account"], "acct_123")
    }

    func testManualClientCredentialsPreservedOnReset() {
        let server = Server(alias: "Manual", kind: .remote_http_sse)
        let registrationEndpoint = URL(string: "https://auth.example.com/register")
        let configuration = OAuthConfiguration(server: server,
                                               registrationEndpoint: registrationEndpoint,
                                               clientId: "manual-client",
                                               clientSecret: "top-secret",
                                               clientSource: .manual)
        server.oauthConfiguration = configuration
        server.oauthState = OAuthState(server: server, serializedAuthState: Data([0x00, 0x01]), isActive: true)
        server.headers.append(HeaderBinding(server: server,
                                            header: "Authorization",
                                            valueSource: .oauthAccessToken))

        OAuthService.shared.resetAuthorizationState(for: server, clearClient: true)

        XCTAssertEqual(server.oauthConfiguration?.clientId, "manual-client")
        XCTAssertEqual(server.oauthConfiguration?.clientSecret, "top-secret")
        XCTAssertEqual(server.oauthConfiguration?.clientSource, .manual)
        XCTAssertEqual(server.oauthStatus, .unauthorized)
    }

    func testInitialHeaderRebuildSkipsForcedRefresh() async {
        let server = Server(alias: "Refresh", kind: .remote_http_sse)
        server.baseURL = "https://api.example.com"
        let state = OAuthState(server: server, serializedAuthState: Data(), isActive: true)
        let formatter = ISO8601DateFormatter()
        state.providerMetadata = [
            "access_expires_at": formatter.string(from: Date().addingTimeInterval(3600)),
            "access_marked_invalid": "false"
        ]
        server.oauthState = state
        server.headers.append(HeaderBinding(server: server,
                                            header: "Authorization",
                                            valueSource: .oauthAccessToken))

        XCTAssertFalse(OAuthService.shared.shouldRefreshAccessToken(for: server))
        XCTAssertNil(server.oauthState?.lastTokenRefresh)

        let headers = await SDKRemoteHTTPProvider.refreshedHeaders(
            for: server,
            requiresOAuth: true,
            forceRefresh: false,
            origin: OAuthConstants.clientOrigin,
            includeAuthorizationBackfill: true
        )

        XCTAssertEqual(headers["Origin"], OAuthConstants.clientOrigin)
        XCTAssertNil(server.oauthState?.lastTokenRefresh)
        XCTAssertFalse(OAuthService.shared.shouldRefreshAccessToken(for: server))
    }

    func testRegistrationFallbackRewritesEndpoints() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let project = Project(name: "Fallback", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "Jira", kind: .remote_http_sse)
        server.baseURL = "https://mcp.atlassian.com/v1/sse"
        context.insert(server)
        try context.save()

        let protectedURL = URL(string: "https://mcp.atlassian.com/.well-known/oauth-protected-resource")!
        let authorizationMetadataURL = URL(string: "https://mcp.atlassian.com/.well-known/oauth-authorization-server")!
        let workerRegistrationURL = URL(string: "https://workers.example.com/v1/register")!
        let workerTokenURL = URL(string: "https://workers.example.com/v1/token")!
        let fallbackRegistrationURL = URL(string: "https://mcp.atlassian.com/v1/register")!
        let fallbackTokenURL = URL(string: "https://mcp.atlassian.com/v1/token")!

        OAuthMockURLProtocol.handlers = [
            protectedURL: { _ in
                let body: [String: Any] = [
                    "resource": "https://mcp.atlassian.com",
                    "authorization_servers": ["https://mcp.atlassian.com"],
                    "scopes_supported": ["read"],
                    "registration_endpoint": workerRegistrationURL.absoluteString
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (200, ["Content-Type": "application/json"], data)
            },
            URL(string: "https://mcp.atlassian.com")!: { _ in
                return (404, [:], nil)
            },
            authorizationMetadataURL: { _ in
                let body: [String: Any] = [
                    "authorization_endpoint": "https://mcp.atlassian.com/v1/authorize",
                    "token_endpoint": workerTokenURL.absoluteString,
                    "registration_endpoint": workerRegistrationURL.absoluteString,
                    "scopes_supported": ["read"],
                    "code_challenge_methods_supported": ["S256"]
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (200, ["Content-Type": "application/json"], data)
            },
            workerRegistrationURL: { _ in
                throw URLError(.cannotConnectToHost)
            },
            fallbackRegistrationURL: { _ in
                let body: [String: Any] = [
                    "client_id": "fallback-client",
                    "client_secret": "fallback-secret"
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (201, ["Content-Type": "application/json"], data)
            }
        ]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OAuthService.shared.configure(urlSession: session)

        defer {
            OAuthService.shared.configure(urlSession: .shared)
            OAuthMockURLProtocol.handlers = [:]
        }

        await OAuthService.shared.runAuthDiscovery(server: server, wwwAuthenticate: nil)
        try context.save()

        guard let oauthConfiguration = server.oauthConfiguration else {
            return XCTFail("OAuth configuration should exist")
        }

        XCTAssertEqual(oauthConfiguration.registrationEndpoint, workerRegistrationURL)
        XCTAssertEqual(oauthConfiguration.tokenEndpoint, workerTokenURL)

        let redirectURL = URL(string: "http://localhost:4567/oauth/callback")!
        try await OAuthService.shared.registerClientIfNeeded(configuration: oauthConfiguration,
                                                             redirectURL: redirectURL)

        XCTAssertEqual(oauthConfiguration.clientId, "fallback-client")
        XCTAssertEqual(oauthConfiguration.registrationEndpoint, fallbackRegistrationURL)
        XCTAssertEqual(oauthConfiguration.tokenEndpoint, fallbackTokenURL)
    }
}

private final class OAuthMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (status: Int, headers: [String: String], data: Data?)

    static var handlers: [URL: Handler] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return handlers.keys.contains(url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard let handler = OAuthMockURLProtocol.handlers[url] else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let result = try handler(request)
            let response = HTTPURLResponse(url: url,
                                           statusCode: result.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }
}
