//
//  OAuthService.swift
//  MCP Bundler
//
//  OAuth discovery and authorization scaffolding.
//

import Foundation
import SwiftData
import Combine
import OSLog
import AppAuth
import AppKit

@MainActor
final class OAuthService: ObservableObject {
    static let shared = OAuthService()

    @Published private(set) var isAuthorizing: Bool = false

    private var urlSession: URLSession
    private var discoveryTasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var capabilityRefreshTasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var redirectHandlers: [PersistentIdentifier: OIDRedirectHTTPHandler] = [:]
    private let logger = Logger(subsystem: "MCPBundler", category: "oauth")
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?
    private let redirectScheme = "mcpbundler"
    private let loopbackSuccessURL: URL? = nil
    private let defaultClientName = "MCP Bundler"
    private let defaultClientURIString = "https://mcp-bundler.maketry.xyz"
    private let defaultSoftwareId = "3b8b0ce9-6c53-45c4-9f0a-8e3f4bc2a0f1"

    private init(session: URLSession = .shared) {
        // Our own URLSession for ancillary calls.
        self.urlSession = session

        // Ensure AppAuth uses JSON responses for token exchanges (GitHub returns
        // form-encoded without an Accept header). Setting a session with
        // `Accept: application/json` avoids JSON parse failures.
        let cfg = URLSessionConfiguration.default
        var hdrs = cfg.httpAdditionalHeaders ?? [:]
        hdrs["Accept"] = "application/json"
        cfg.httpAdditionalHeaders = hdrs
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        #if canImport(AppAuth)
        let appAuthSession = URLSession(configuration: cfg)
        OIDURLSessionProvider.setSession(appAuthSession)
        #endif
    }

    private enum ToastKind: String {
        case success
        case warning
        case info
    }

    func configure(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    private var softwareVersionString: String {
        if let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !shortVersion.isEmpty {
            return shortVersion
        }
        if let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           !buildVersion.isEmpty {
            return buildVersion
        }
        return "dev"
    }

    func handleAuthRequired(server: Server, wwwAuthenticate: String?) {
        guard server.kind == .remote_http_sse else { return }

        let serverID = server.persistentModelID
        if discoveryTasks[serverID] != nil {
            logger.debug("Discovery already running for server \(server.alias, privacy: .public)")
            return
        }

        let header = WWWAuthenticateHeader.parse(wwwAuthenticate)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performAuthRequired(serverID: serverID, server: server, header: header)
        }
        discoveryTasks[serverID] = task
    }

    func discoverProtectedResourceMetadata(server: Server, forceURL: URL? = nil) async {
        let configuration = ensureConfiguration(on: server)
        do {
            _ = try await fetchProtectedResourceMetadata(server: server,
                                                          configuration: configuration,
                                                          explicitURL: forceURL,
                                                          header: nil)
        } catch {
            logger.error("Manual PRM discovery failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
            server.oauthStatus = .error
        }
    }

    func discoverAuthorizationServerMetadata(configuration: OAuthConfiguration) async {
        do {
            _ = try await fetchAuthorizationServerMetadata(configuration: configuration,
                                                            protectedMetadata: nil)
        } catch {
            logger.error("Manual AS discovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func registerClientIfNeeded(configuration: OAuthConfiguration,
                                redirectURL: URL,
                                allowFallback: Bool = true) async throws {
        if let clientId = configuration.clientId, !clientId.isEmpty {
            return
        }

        guard let server = configuration.server else {
            throw OAuthServiceError.clientRegistrationFailed(statusCode: nil, message: "Missing server reference.")
        }

        guard let registrationEndpoint = configuration.registrationEndpoint else {
            logger.info("No registration endpoint advertised for \(server.alias, privacy: .public); skipping dynamic registration.")
            return
        }

        let clientName = "\(defaultClientName) (\(server.alias))"
        let payload = OAuthClientRegistrationRequest(
            redirectUris: [redirectURL.absoluteString],
            tokenEndpointAuthMethod: "none",
            grantTypes: ["authorization_code", "refresh_token"],
            responseTypes: ["code"],
            clientName: clientName,
            clientURI: defaultClientURIString,
            softwareId: defaultSoftwareId,
            softwareVersion: softwareVersionString
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let payloadData = try encoder.encode(payload)

        var request = URLRequest(url: registrationEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(OAuthConstants.mcpProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = payloadData

        let requestHeaders = sanitizedHeaders(request.allHTTPHeaderFields ?? [:])
        let requestBodyPreview = makeRequestPreview(from: payloadData)

        logger.debug("Starting OAuth client registration at \(registrationEndpoint.absoluteString, privacy: .public)")
        OAuthDebugLogger.log("Posting dynamic client registration", category: "oauth.registration", server: server, metadata: [
            "endpoint": registrationEndpoint.absoluteString,
            "redirect_uri": redirectURL.absoluteString,
            "client_name": clientName
        ])

        var didRecordAttempt = false

        do {
            let (data, response) = try await urlSession.data(for: request)
            let responseBodyPreview = makeResponsePreview(from: data)

            guard let http = response as? HTTPURLResponse else {
                recordDiagnostics(on: server,
                                  url: registrationEndpoint,
                                  method: "POST",
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: requestBodyPreview,
                                  responseHeaders: nil,
                                  statusCode: nil,
                                  message: "Invalid registration response",
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                throw OAuthServiceError.clientRegistrationFailed(statusCode: nil, message: "Invalid HTTP response from registration endpoint.")
            }

            let responseHeaders = sanitizedHeaders(http.headerFieldsAsStrings)

            guard (200..<300).contains(http.statusCode) else {
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                recordDiagnostics(on: server,
                                  url: registrationEndpoint,
                                  method: "POST",
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: requestBodyPreview,
                                  responseHeaders: responseHeaders,
                                  statusCode: http.statusCode,
                                  message: reason,
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                throw OAuthServiceError.clientRegistrationFailed(statusCode: http.statusCode, message: reason)
            }

            let decoded = try JSONDecoder().decode(OAuthClientRegistrationResponse.self, from: data)
            guard !decoded.clientId.isEmpty else {
                recordDiagnostics(on: server,
                                  url: registrationEndpoint,
                                  method: "POST",
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: requestBodyPreview,
                                  responseHeaders: responseHeaders,
                                  statusCode: http.statusCode,
                                  message: "Registration response missing client_id",
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                throw OAuthServiceError.clientRegistrationInvalidResponse
            }

            configuration.clientId = decoded.clientId
            configuration.clientSecret = decoded.clientSecret
            configuration.clientSource = .dynamic

            recordDiagnostics(on: server,
                              url: registrationEndpoint,
                              method: "POST",
                              requestHeaders: requestHeaders,
                              requestBodyPreview: requestBodyPreview,
                              responseHeaders: responseHeaders,
                              statusCode: http.statusCode,
                              message: "Client registration succeeded",
                              responseBodyPreview: responseBodyPreview)
            didRecordAttempt = true
            logger.info("Dynamic client registration succeeded for \(server.alias, privacy: .public)")
            var debugMetadata: [String: String] = [
                "client_id": decoded.clientId
            ]
            if let secret = decoded.clientSecret, !secret.isEmpty {
                debugMetadata["client_secret"] = OAuthDebugLogger.summarizeToken(secret)
            }
            OAuthDebugLogger.log("Dynamic client registration succeeded", category: "oauth.registration", server: server, metadata: debugMetadata)
        } catch {
            if !didRecordAttempt {
                recordDiagnostics(on: server,
                                  url: registrationEndpoint,
                                  method: "POST",
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: requestBodyPreview,
                                  responseHeaders: nil,
                                  statusCode: nil,
                                  message: error.localizedDescription,
                                  responseBodyPreview: nil)
            }
            if allowFallback,
               let fallbackBase = fallbackBaseURL(for: configuration, server: server),
               let fallbackRegistration = rebuildEndpoint(registrationEndpoint, withBase: fallbackBase),
               fallbackRegistration != registrationEndpoint,
               shouldRetryWithFallback(error) {
                recordDiagnostics(on: server,
                                  url: registrationEndpoint,
                                  method: "POST",
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: requestBodyPreview,
                                  responseHeaders: nil,
                                  statusCode: nil,
                                  message: "Retrying dynamic registration via fallback host",
                                  responseBodyPreview: nil)
                OAuthDebugLogger.log("Retrying dynamic client registration via fallback host",
                                     category: "oauth.registration",
                                     server: server,
                                     metadata: [
                                        "original_endpoint": registrationEndpoint.absoluteString,
                                        "fallback_endpoint": fallbackRegistration.absoluteString
                                     ])
                configuration.registrationEndpoint = fallbackRegistration
                if let tokenEndpoint = configuration.tokenEndpoint,
                   let rewritten = rebuildEndpoint(tokenEndpoint, withBase: fallbackBase) {
                    configuration.tokenEndpoint = rewritten
                }
                if let authorizationEndpoint = configuration.authorizationEndpoint,
                   authorizationEndpoint.host == registrationEndpoint.host,
                   let rewrittenAuthorize = rebuildEndpoint(authorizationEndpoint, withBase: fallbackBase) {
                    configuration.authorizationEndpoint = rewrittenAuthorize
                }
                return try await registerClientIfNeeded(configuration: configuration,
                                                        redirectURL: redirectURL,
                                                        allowFallback: false)
            }

            OAuthDebugLogger.log("Dynamic client registration failed: \(error.localizedDescription)",
                                 category: "oauth.registration",
                                 server: server)
            throw error
        }
    }

    func startAuthorizationFlow(server: Server, configuration: OAuthConfiguration) async {
        guard server.oauthStatus != .refreshing else { return }

        let serverID = server.persistentModelID
        let redirectHandler = redirectHandlers[serverID] ?? {
            let handler = OIDRedirectHTTPHandler(successURL: loopbackSuccessURL)
            redirectHandlers[serverID] = handler
            return handler
        }()

        var listenerNSError: NSError?
        let preferredPort = preferredLoopbackPort(for: server)
        var loopbackBaseURL: URL?
        if preferredPort > 0 {
            loopbackBaseURL = redirectHandler.startHTTPListener(&listenerNSError, withPort: preferredPort)
            if let error = listenerNSError {
                logger.debug("Preferred loopback port \(preferredPort) unavailable for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to random port.")
                listenerNSError = nil
                loopbackBaseURL = redirectHandler.startHTTPListener(&listenerNSError)
            }
        } else {
            loopbackBaseURL = redirectHandler.startHTTPListener(&listenerNSError)
        }

        if let listenerError = listenerNSError {
            server.oauthStatus = .error
            let message = listenerError.localizedDescription
            logger.error("Failed to start OAuth loopback listener for \(server.alias, privacy: .public): \(message, privacy: .public)")
            redirectHandler.cancelHTTPListener()
            redirectHandlers.removeValue(forKey: serverID)
            return
                }
                guard let loopbackBaseURL else {
                    server.oauthStatus = .error
                    logger.error("Loopback listener returned no URL for \(server.alias, privacy: .public)")
                    redirectHandler.cancelHTTPListener()
                    redirectHandlers.removeValue(forKey: serverID)
                    resetAuthorizationState(for: server, clearClient: false)
                    return
                }

                guard var redirectComponents = URLComponents(url: loopbackBaseURL, resolvingAgainstBaseURL: false) else {
                    server.oauthStatus = .error
                    logger.error("Failed to derive redirect components for \(server.alias, privacy: .public)")
                    redirectHandler.cancelHTTPListener()
                    redirectHandlers.removeValue(forKey: serverID)
                    resetAuthorizationState(for: server, clearClient: false)
                    return
                }
                redirectComponents.host = "localhost"
                let basePath = redirectComponents.path.hasSuffix("/") ? redirectComponents.path.dropLast() : Substring(redirectComponents.path)
                redirectComponents.path = "\(basePath)/oauth/callback"
                guard let redirectURL = redirectComponents.url else {
                    server.oauthStatus = .error
                    logger.error("Failed to construct redirect URL for \(server.alias, privacy: .public)")
                    redirectHandler.cancelHTTPListener()
                    redirectHandlers.removeValue(forKey: serverID)
                    resetAuthorizationState(for: server, clearClient: false)
                    return
                }

                if configuration.clientId?.isEmpty ?? true {
                    do {
                        try await registerClientIfNeeded(configuration: configuration, redirectURL: redirectURL)
                    } catch {
                        server.oauthStatus = .error
                        let userMessage = formattedRegistrationFailureMessage(error,
                                                                             registrationEndpoint: configuration.registrationEndpoint)
                        var log = server.oauthDiagnostics
                        log.lastErrorDescription = userMessage
                        server.oauthDiagnostics = log
                        logger.error("OAuth client registration failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        publishToast(for: server,
                                     title: "OAuth client registration failed",
                                     message: userMessage,
                                     kind: .warning,
                                     notify: true)
                        redirectHandler.cancelHTTPListener()
                        redirectHandlers.removeValue(forKey: serverID)
                        resetAuthorizationState(for: server, clearClient: true)
                        return
                    }
                }

                // Clear stale dynamic client credentials for providers that require
                // fresh registration (e.g., Atlassian) when we're not currently
                // authorized and the user is initiating a new sign-in.
                maybeClearStaleDynamicClientCredentials(server: server, configuration: configuration)

                guard let clientID = configuration.clientId, !clientID.isEmpty else {
                    server.oauthStatus = .error
                    var log = server.oauthDiagnostics
                    log.lastErrorDescription = "OAuth client credentials are required before starting authorization."
                    server.oauthDiagnostics = log
                    logger.error("Missing client ID for OAuth flow (server=\(server.alias, privacy: .public))")
                    redirectHandler.cancelHTTPListener()
                    redirectHandlers.removeValue(forKey: serverID)
                    resetAuthorizationState(for: server, clearClient: true)
                    return
                }

        guard let authorizationEndpoint = configuration.authorizationEndpoint,
              let tokenEndpoint = configuration.tokenEndpoint else {
            server.oauthStatus = .error
            var log = server.oauthDiagnostics
            log.lastErrorDescription = "Authorization or token endpoint missing after discovery."
            server.oauthDiagnostics = log
            logger.error("Authorization flow missing endpoints for \(server.alias, privacy: .public)")
            redirectHandler.cancelHTTPListener()
            redirectHandlers.removeValue(forKey: serverID)
            return
        }

        var loginMetadata: [String: String] = [
            "authorization_endpoint": authorizationEndpoint.absoluteString,
            "token_endpoint": tokenEndpoint.absoluteString,
            "redirect_uri": redirectURL.absoluteString,
            "client_id": clientID
        ]
        if let resource = configuration.resourceURI?.absoluteString {
            loginMetadata["resource"] = resource
        }
        OAuthDebugLogger.log("Starting OAuth authorization flow", category: "oauth.login", server: server, metadata: loginMetadata)

        let serviceConfiguration = OIDServiceConfiguration(
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint
        )

        var additionalParameters: [String: String] = [:]
        if let resource = configuration.resourceURI?.absoluteString {
            additionalParameters["resource"] = resource
        }

        // Do not force OIDC scope; some providers (e.g., GitHub) do not support it.
        let scopes = configuration.scopes

        let request = OIDAuthorizationRequest(
            configuration: serviceConfiguration,
            clientId: clientID,
            clientSecret: configuration.clientSecret,
            scopes: scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: additionalParameters
        )

        server.oauthStatus = .refreshing
        isAuthorizing = true

        if let flow = currentAuthorizationFlow {
            await flow.cancel()
        }
        let session = OIDAuthState.authState(
            byPresenting: request,
            externalUserAgent: OIDExternalUserAgentMac()
        ) { [weak self] authState, error in
            guard let self else { return }
            Task { @MainActor in
                self.isAuthorizing = false
                self.currentAuthorizationFlow = nil
                if let handler = self.redirectHandlers[serverID] {
                    handler.currentAuthorizationFlow = nil
                    self.redirectHandlers.removeValue(forKey: serverID)
                }
                if let authState {
                    self.logger.info("Authorization completed for \(server.alias, privacy: .public)")
                    self.persist(authState: authState, for: server)
                    OAuthDebugLogger.log("OAuth authorization completed", category: "oauth.login", server: server)
                    server.oauthStatus = .authorized
                    self.scheduleCapabilityRefresh(for: server)
                    let successTitle = "Signed in to \(server.alias)"
                    let successMessage = "OAuth authorization completed successfully."
                    self.publishToast(for: server,
                                      title: successTitle,
                                      message: successMessage,
                                      kind: .success)
                } else if let error {
                    self.logger.error("Authorization failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    OAuthDebugLogger.log("OAuth authorization failed: \(error.localizedDescription)",
                                         category: "oauth.login",
                                         server: server)
                    // If this provider uses dynamic registration and we're not
                    // using manual credentials, clear client credentials so the
                    // next attempt can re-register.
                    let shouldClear = configuration.registrationEndpoint != nil && !server.usesManualCredentials
                    self.resetAuthorizationState(for: server, clearClient: shouldClear)
                    server.oauthStatus = .error
                    let failureTitle = "OAuth sign-in failed"
                    let failureMessage = error.localizedDescription
                    self.publishToast(for: server,
                                      title: failureTitle,
                                      message: failureMessage,
                                      kind: .warning,
                                      notify: true)
                } else {
                    OAuthDebugLogger.log("OAuth authorization was cancelled", category: "oauth.login", server: server)
                    self.resetAuthorizationState(for: server, clearClient: false)
                    server.oauthStatus = .unauthorized
                    self.publishToast(for: server,
                                      title: "OAuth sign-in cancelled",
                                      message: "The browser flow was cancelled before completion.",
                                      kind: .info)
                }
                try? server.modelContext?.save()
            }
        }
        redirectHandler.currentAuthorizationFlow = session
        currentAuthorizationFlow = session
    }

    func performActionWithFreshTokens(server: Server,
                                      announce: Bool = false,
                                      completion: @escaping (String?) -> Void) {
        guard let oauthState = server.oauthState,
              let authState = Self.decodeAuthState(from: oauthState.serializedAuthState) else {
            completion(nil)
            return
        }

        server.oauthStatus = .refreshing
        OAuthDebugLogger.log("Refreshing OAuth tokens", category: "oauth.refresh", server: server)

        authState.performAction { [weak self] accessToken, _, error in
            Task { @MainActor in
                guard let self else { completion(nil); return }
                defer {
                    do {
                        try server.modelContext?.save()
                    } catch {
                        self.logger.error("Failed saving refreshed auth state: \(error.localizedDescription, privacy: .public)")
                    }
                }

                if let error {
                    self.logger.error("Refreshing OAuth tokens failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    server.oauthStatus = .error
                    self.resetAuthorizationState(for: server, clearClient: false)
                    OAuthDebugLogger.log("OAuth token refresh failed: \(error.localizedDescription)",
                                         category: "oauth.refresh",
                                         server: server)
                    let title = "OAuth refresh failed"
                    self.publishToast(for: server,
                                      title: title,
                                      message: error.localizedDescription,
                                      kind: .warning,
                                      notify: true)
                    completion(nil)
                    return
                }

                guard let accessToken else {
                    self.logger.error("OAuth token refresh returned without an access token for \(server.alias, privacy: .public)")
                    server.oauthStatus = .error
                    self.resetAuthorizationState(for: server, clearClient: false)
                    OAuthDebugLogger.log("OAuth token refresh produced no access token", category: "oauth.refresh", server: server)
                    self.publishToast(for: server,
                                      title: "OAuth refresh failed",
                                      message: "No access token was returned by the authorization server.",
                                      kind: .warning,
                                      notify: true)
                    completion(nil)
                    return
                }

                if let archived = Self.archiveAuthState(authState) {
                    oauthState.serializedAuthState = archived
                }
                oauthState.lastTokenRefresh = Date()
                oauthState.isActive = true
                server.oauthStatus = .authorized
                self.updateProviderMetadata(from: authState, for: server, category: "oauth.refresh")
                self.captureTokenTTL(from: authState, for: server, category: "oauth.refresh")
                OAuthDebugLogger.log("OAuth token refresh succeeded", category: "oauth.refresh", server: server, metadata: [
                    "access_token": OAuthDebugLogger.summarizeToken(accessToken)
                ])
                if announce {
                    self.publishToast(for: server,
                                      title: "Session refreshed",
                                      message: "OAuth tokens for \(server.alias) were refreshed.",
                                      kind: .success)
                }
                completion(accessToken)
                NotificationCenter.default.post(name: .oauthTokensRefreshed,
                                                object: nil,
                                                userInfo: ["alias": server.alias,
                                                           "serverID": String(describing: server.persistentModelID)])
                self.scheduleCapabilityRefresh(for: server)
            }
        }
    }

    nonisolated(unsafe) func resolveAccessToken(for server: Server) -> String? {
        guard let state = server.oauthState, state.isActive, !state.serializedAuthState.isEmpty else { return nil }
        guard let authState = Self.decodeAuthState(from: state.serializedAuthState) else { return nil }
        return authState.lastTokenResponse?.accessToken
    }

    func refreshAccessToken(for server: Server, announce: Bool = false) async -> String? {
        await withCheckedContinuation { continuation in
            performActionWithFreshTokens(server: server, announce: announce) { token in
                continuation.resume(returning: token)
            }
        }
    }

    private func scheduleCapabilityRefresh(for server: Server) {
        guard server.kind == .remote_http_sse else { return }
        let serverID = server.persistentModelID
        if capabilityRefreshTasks[serverID] != nil { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshRemoteCapabilities(for: server)
            await MainActor.run {
                self.capabilityRefreshTasks.removeValue(forKey: serverID)
            }
        }
        capabilityRefreshTasks[serverID] = task
    }

    @MainActor
    private func refreshRemoteCapabilities(for server: Server) async {
        guard server.kind == .remote_http_sse else { return }
        guard let context = server.modelContext else { return }
        let provider = CapabilitiesService.provider(for: server)
        do {
            let capabilities = try await provider.fetchCapabilities(for: server)
            if let data = try? JSONEncoder().encode(capabilities) {
                server.replaceCapabilityCache(payload: data, generatedAt: Date(), in: context)
            }
            server.lastHealth = .healthy
            server.lastCheckedAt = Date()
            try context.save()
            if let project = server.project {
                do {
                    try await ProjectSnapshotCache.rebuildSnapshot(for: project)
                } catch {
                    logger.error("Snapshot rebuild failed after OAuth for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                BundlerEventService.emit(in: context, project: project, servers: [server], type: .serverUpdated)
            }
            let toolCount = capabilities.tools.count
            OAuthDebugLogger.log("Capability refresh completed", category: "oauth.capabilities", server: server, metadata: ["tools": String(toolCount)])
        } catch {
            server.lastHealth = .unhealthy
            server.lastCheckedAt = Date()
            try? context.save()
            OAuthDebugLogger.log("Capability refresh failed: \(error.localizedDescription)", category: "oauth.capabilities", server: server)
        }
    }

    func runAuthDiscovery(server: Server, wwwAuthenticate: String?) async {
        let header = WWWAuthenticateHeader.parse(wwwAuthenticate)
        await performAuthRequired(serverID: server.persistentModelID, server: server, header: header)
    }

    @MainActor
    func handleRedirectURL(_ url: URL) -> Bool {
        guard let flow = currentAuthorizationFlow else { return false }
        let handled = flow.resumeExternalUserAgentFlow(with: url)
        if handled {
            currentAuthorizationFlow = nil
        }
        return handled
    }

    // MARK: - Internal helpers

    private func performAuthRequired(serverID: PersistentIdentifier,
                                     server: Server,
                                     header: WWWAuthenticateHeader?) async {
        defer { discoveryTasks.removeValue(forKey: serverID) }

        guard let context = server.modelContext else {
            logger.error("Server context unavailable for OAuth discovery")
            return
        }

        OAuthDebugLogger.log("Starting OAuth discovery", category: "oauth.discovery", server: server, metadata: {
            var data: [String: String] = [:]
            if let resource = header?.resource?.absoluteString {
                data["resource"] = resource
            }
            if let resourceMetadata = header?.resourceMetadata?.absoluteString {
                data["resource_metadata"] = resourceMetadata
            }
            if let scopes = header?.scopes, !scopes.isEmpty {
                data["scopes"] = scopes.joined(separator: " ")
            }
            return data
        }())

        let configuration = ensureConfiguration(on: server)
        apply(header: header, to: configuration)
        server.oauthStatus = .refreshing

        var protectedMetadata: ProtectedResourceMetadata?
        do {
            let metadata = try await fetchProtectedResourceMetadata(server: server,
                                                                    configuration: configuration,
                                                                    explicitURL: nil,
                                                                    header: header)
            apply(protectedMetadata: metadata, to: configuration)
            protectedMetadata = metadata
        } catch let error as OAuthServiceError {
            switch error {
            case .protectedResourceMetadataNotFound:
                var log = server.oauthDiagnostics
                log.lastErrorDescription = error.localizedDescription
                server.oauthDiagnostics = log
                logger.warning("Protected resource metadata missing for \(server.alias, privacy: .public); continuing with authorization metadata heuristics.")
            default:
                var log = server.oauthDiagnostics
                log.lastErrorDescription = error.localizedDescription
                server.oauthDiagnostics = log
                resetAuthorizationState(for: server, clearClient: false)
                server.oauthStatus = .error
                logger.error("OAuth discovery failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? context.save()
                return
            }
        } catch {
            var log = server.oauthDiagnostics
            log.lastErrorDescription = error.localizedDescription
            server.oauthDiagnostics = log
            resetAuthorizationState(for: server, clearClient: false)
            server.oauthStatus = .error
            logger.error("OAuth discovery failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? context.save()
            return
        }

        do {
            let authorizationMetadata = try await fetchAuthorizationServerMetadata(configuration: configuration,
                                                                                   protectedMetadata: protectedMetadata)
            apply(authorizationMetadata: authorizationMetadata, to: configuration)
            var log = server.oauthDiagnostics
            log.lastErrorDescription = nil
            server.oauthDiagnostics = log
            server.oauthStatus = .unauthorized
        } catch {
            var log = server.oauthDiagnostics
            log.lastErrorDescription = error.localizedDescription
            server.oauthDiagnostics = log
            resetAuthorizationState(for: server, clearClient: false)
            server.oauthStatus = .error
            logger.error("OAuth discovery failed for \(server.alias, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        OAuthDebugLogger.log("OAuth discovery finished with status=\(server.oauthStatus.rawValue)",
                             category: "oauth.discovery",
                             server: server)
        try? context.save()
    }

    private func publishToast(for server: Server,
                              title: String,
                              message: String,
                              kind: ToastKind,
                              notify: Bool = false) {
        NotificationCenter.default.post(
            name: .oauthToastRequested,
            object: nil,
            userInfo: [
                "title": title,
                "message": message,
                "alias": server.alias,
                "kind": kind.rawValue,
                "notify": notify
            ]
        )
    }

    private func ensureConfiguration(on server: Server) -> OAuthConfiguration {
        if let configuration = server.oauthConfiguration {
            return configuration
        }
        let configuration = OAuthConfiguration(server: server)
        server.oauthConfiguration = configuration
        return configuration
    }

    private func apply(header: WWWAuthenticateHeader?, to configuration: OAuthConfiguration) {
        guard let header else { return }
        if let resource = header.resource {
            configuration.resourceURI = resource
        }
        if !header.scopes.isEmpty {
            configuration.scopes = header.scopes
        }
        configuration.metadataVersion = OAuthConfiguration.defaultMetadataVersion
        configuration.discoveredAt = Date()
    }

    private func apply(authorizationMetadata: AuthorizationServerMetadata, to configuration: OAuthConfiguration) {
        configuration.authorizationEndpoint = authorizationMetadata.authorizationEndpoint
        configuration.tokenEndpoint = authorizationMetadata.tokenEndpoint
        configuration.registrationEndpoint = authorizationMetadata.registrationEndpoint
        configuration.jwksEndpoint = authorizationMetadata.jwksURI
        if !authorizationMetadata.scopesSupported.isEmpty {
            configuration.scopes = authorizationMetadata.scopesSupported
        }
        configuration.usePKCE = authorizationMetadata.supportsS256PKCE
        configuration.metadataVersion = authorizationMetadata.metadataVersion ?? configuration.metadataVersion
        configuration.discoveredAt = Date()
    }

    private func fetchProtectedResourceMetadata(server: Server,
                                                 configuration: OAuthConfiguration,
                                                 explicitURL: URL?,
                                                 header: WWWAuthenticateHeader?) async throws -> ProtectedResourceMetadata {
        let candidates = try makeProtectedResourceCandidates(server: server,
                                                             configuration: configuration,
                                                             explicitURL: explicitURL,
                                                             header: header)

        if !candidates.isEmpty {
            let summary = candidates.map { $0.absoluteString }.joined(separator: ", ")
            OAuthDebugLogger.log("PRM discovery candidates: \(summary)",
                                 category: "oauth.discovery",
                                 server: server)
        }

        var attempts: [URL] = []
        for candidate in candidates {
            do {
                OAuthDebugLogger.log("Requesting PRM from \(candidate.absoluteString)",
                                     category: "oauth.discovery",
                                     server: server)
                let metadata: ProtectedResourceMetadata = try await fetchMetadata(from: candidate, server: server)
                apply(protectedMetadata: metadata, to: configuration)
                let authServers = (metadata.authorizationServers ?? []).map { $0.absoluteString }.joined(separator: ", ")
                let scopes = metadata.scopesSupported.joined(separator: " ")
                var debugMetadata: [String: String] = [:]
                if let resource = metadata.resource, !resource.isEmpty {
                    debugMetadata["resource"] = resource
                }
                if !authServers.isEmpty {
                    debugMetadata["authorization_servers"] = authServers
                }
                if !scopes.isEmpty {
                    debugMetadata["scopes"] = scopes
                }
                OAuthDebugLogger.log("PRM succeeded at \(candidate.absoluteString)",
                                     category: "oauth.discovery",
                                     server: server,
                                     metadata: debugMetadata)
                logger.debug("Loaded PRM from \(candidate.absoluteString, privacy: .private)")
                return metadata
            } catch {
                attempts.append(candidate)
                OAuthDebugLogger.log("PRM failed at \(candidate.absoluteString): \(error.localizedDescription)",
                                     category: "oauth.discovery",
                                     server: server)
                logger.debug("PRM fetch failed at \(candidate.absoluteString, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }

        throw OAuthServiceError.protectedResourceMetadataNotFound(candidates: attempts)
    }

    private func apply(protectedMetadata: ProtectedResourceMetadata, to configuration: OAuthConfiguration) {
        if let resource = protectedMetadata.resource, let url = URL(string: resource) {
            configuration.resourceURI = url
        }
        if !protectedMetadata.scopesSupported.isEmpty {
            configuration.scopes = protectedMetadata.scopesSupported
        }
        configuration.registrationEndpoint = protectedMetadata.registrationEndpoint ?? configuration.registrationEndpoint
        configuration.metadataVersion = protectedMetadata.metadataVersion ?? configuration.metadataVersion
        configuration.discoveredAt = Date()
    }

    private func fetchAuthorizationServerMetadata(configuration: OAuthConfiguration,
                                                   protectedMetadata: ProtectedResourceMetadata?) async throws -> AuthorizationServerMetadata {
        let candidates = try makeAuthorizationServerCandidates(configuration: configuration,
                                                               protectedMetadata: protectedMetadata)

        if let server = configuration.server, !candidates.isEmpty {
            let summary = candidates.map { $0.absoluteString }.joined(separator: ", ")
            OAuthDebugLogger.log("Authorization server candidates: \(summary)",
                                 category: "oauth.discovery",
                                 server: server)
        }

        var attempts: [URL] = []
        for candidate in candidates {
            do {
                if let server = configuration.server {
                    OAuthDebugLogger.log("Requesting AS metadata from \(candidate.absoluteString)",
                                         category: "oauth.discovery",
                                         server: server)
                }
                let metadata: AuthorizationServerMetadata = try await fetchMetadata(from: candidate, server: configuration.server)
                if let server = configuration.server {
                    var debugMetadata: [String: String] = [:]
                    if let authorizationEndpoint = metadata.authorizationEndpoint?.absoluteString {
                        debugMetadata["authorization_endpoint"] = authorizationEndpoint
                    }
                    if let tokenEndpoint = metadata.tokenEndpoint?.absoluteString {
                        debugMetadata["token_endpoint"] = tokenEndpoint
                    }
                    if let registrationEndpoint = metadata.registrationEndpoint?.absoluteString {
                        debugMetadata["registration_endpoint"] = registrationEndpoint
                    }
                    OAuthDebugLogger.log("AS metadata succeeded at \(candidate.absoluteString)",
                                         category: "oauth.discovery",
                                         server: server,
                                         metadata: debugMetadata)
                }
                logger.debug("Loaded AS metadata from \(candidate.absoluteString, privacy: .public)")
                return metadata
            } catch {
                attempts.append(candidate)
                if let server = configuration.server {
                    OAuthDebugLogger.log("AS metadata failed at \(candidate.absoluteString): \(error.localizedDescription)",
                                         category: "oauth.discovery",
                                         server: server)
                }
                logger.debug("AS metadata fetch failed at \(candidate.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if let server = configuration.server,
           let fallback = legacyAuthorizationMetadata(for: configuration, server: server) {
            if let anchor = fallback.authorizationEndpoint ?? fallback.tokenEndpoint {
                recordDiagnostics(on: server,
                                  url: anchor,
                                  method: "GET",
                                  requestHeaders: nil,
                                  requestBodyPreview: nil,
                                  responseHeaders: nil,
                                  statusCode: nil,
                                  message: "Using legacy OAuth endpoint fallback",
                                  responseBodyPreview: nil)
                var debugMetadata: [String: String] = [:]
                if let authorizationEndpoint = fallback.authorizationEndpoint?.absoluteString {
                    debugMetadata["authorization_endpoint"] = authorizationEndpoint
                }
                if let tokenEndpoint = fallback.tokenEndpoint?.absoluteString {
                    debugMetadata["token_endpoint"] = tokenEndpoint
                }
                OAuthDebugLogger.log("Using legacy OAuth endpoints after discovery failed",
                                     category: "oauth.discovery",
                                     server: server,
                                     metadata: debugMetadata)
            }
            logger.warning("Falling back to legacy OAuth endpoints for \(server.alias, privacy: .public)")
            return fallback
        }

        throw OAuthServiceError.authorizationServerMetadataNotFound(candidates: attempts)
    }

    private func fetchMetadata<T: Decodable>(from url: URL, server: Server?) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(OAuthConstants.mcpProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")

        let httpMethod = request.httpMethod ?? "GET"
        let requestHeaders = sanitizedHeaders(request.allHTTPHeaderFields ?? [:])
        let headersDescription = requestHeaders?
            .sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ") ?? "none"

        logger.debug("OAuth metadata request \(httpMethod, privacy: .public) \(url.absoluteString, privacy: .public) headers=\(headersDescription, privacy: .public)")

        var didRecordAttempt = false

        do {
            let (data, response) = try await urlSession.data(for: request)
            let responseBodyPreview = makeResponsePreview(from: data)

            guard let http = response as? HTTPURLResponse else {
                recordDiagnostics(on: server,
                                  url: url,
                                  method: httpMethod,
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: nil,
                                  responseHeaders: nil,
                                  statusCode: nil,
                                  message: "Invalid HTTP response",
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                logger.debug("OAuth metadata invalid response from \(url.absoluteString, privacy: .public)")
                throw OAuthServiceError.invalidResponse(url: url)
            }

            let responseHeaders = sanitizedHeaders(http.headerFieldsAsStrings)
            if !(200..<300).contains(http.statusCode) {
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                recordDiagnostics(on: server,
                                  url: url,
                                  method: httpMethod,
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: nil,
                                  responseHeaders: responseHeaders,
                                  statusCode: http.statusCode,
                                  message: reason,
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                logger.debug("OAuth metadata HTTP \(http.statusCode) (\(reason)) from \(url.absoluteString, privacy: .public)")
                throw OAuthServiceError.httpError(url: url, statusCode: http.statusCode)
            }

            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                recordDiagnostics(on: server,
                                  url: url,
                                  method: httpMethod,
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: nil,
                                  responseHeaders: responseHeaders,
                                  statusCode: http.statusCode,
                                  message: "Metadata loaded",
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                logger.debug("OAuth metadata success \(http.statusCode) from \(url.absoluteString, privacy: .public)")
                return decoded
            } catch {
                recordDiagnostics(on: server,
                                  url: url,
                                  method: httpMethod,
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: nil,
                                  responseHeaders: responseHeaders,
                                  statusCode: http.statusCode,
                                  message: "Decoding error: \(error.localizedDescription)",
                                  responseBodyPreview: responseBodyPreview)
                didRecordAttempt = true
                logger.debug("OAuth metadata decode failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw OAuthServiceError.decodingError(url: url, underlying: error)
            }
        } catch {
            if !didRecordAttempt {
                recordDiagnostics(on: server,
                                  url: url,
                                  method: httpMethod,
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: nil,
                                  responseHeaders: nil,
                                  statusCode: nil,
                                  message: error.localizedDescription,
                                  responseBodyPreview: nil)
                logger.debug("OAuth metadata request failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    private func makeProtectedResourceCandidates(server: Server,
                                                 configuration: OAuthConfiguration,
                                                 explicitURL: URL?,
                                                 header: WWWAuthenticateHeader?) throws -> [URL] {
        var candidates: [URL] = []
        if let explicitURL {
            candidates.append(explicitURL)
        }
        if let headerURL = header?.resourceMetadata {
            candidates.append(headerURL)
        }
        if let stored = configuration.resourceURI {
            candidates.append(contentsOf: protectedResourceDiscoveryCandidates(from: stored))
        }

        if let baseString = server.baseURL, let baseURL = URL(string: baseString) {
            candidates.append(contentsOf: protectedResourceDiscoveryCandidates(from: baseURL))
        } else if candidates.isEmpty {
            throw OAuthServiceError.missingBaseURL
        }

        return dedupeURLs(candidates)
    }

    private func makeAuthorizationServerCandidates(configuration: OAuthConfiguration,
                                                   protectedMetadata: ProtectedResourceMetadata?) throws -> [URL] {
        var candidates: [URL] = []
        if let explicit = protectedMetadata?.authorizationServers {
            for url in explicit {
                candidates.append(url)
                candidates.append(contentsOf: authorizationDiscoveryCandidates(from: url))
            }
        }
        if let issuerString = protectedMetadata?.issuer, let issuerURL = URL(string: issuerString) {
            candidates.append(contentsOf: authorizationDiscoveryCandidates(from: issuerURL))
        }
        if let resource = configuration.resourceURI {
            candidates.append(contentsOf: authorizationDiscoveryCandidates(from: resource))
        }
        if let authorizationEndpoint = configuration.authorizationEndpoint {
            candidates.append(authorizationEndpoint)
            candidates.append(contentsOf: authorizationDiscoveryCandidates(from: authorizationEndpoint))
        }
        if let baseString = configuration.server?.baseURL, let baseURL = URL(string: baseString) {
            candidates.append(contentsOf: authorizationDiscoveryCandidates(from: baseURL))
        }

        if candidates.isEmpty {
            throw OAuthServiceError.authorizationServerMetadataNotFound(candidates: [])
        }

        return dedupeURLs(candidates)
    }

    private func protectedResourceDiscoveryCandidates(from base: URL) -> [URL] {
        guard let origin = base.originURL else { return [] }
        var candidates: [URL] = []
        let path = base.discoveryPathComponent

        // Always prefer host-level well-known endpoints first
        if let hostLevel = URL(string: "/.well-known/oauth-protected-resource", relativeTo: origin) {
            candidates.append(hostLevel)
        }

        // Generate path-scoped candidates only for non-Atlassian hosts
        let host = (base.host ?? "").lowercased()
        let allowPathScoped = !host.contains("atlassian")
        if allowPathScoped, !path.isEmpty {
            if let url = URL(string: "/.well-known/oauth-protected-resource\(path)", relativeTo: origin) {
                candidates.append(url)
            }
        }

        return dedupeURLs(candidates)
    }

    private func authorizationDiscoveryCandidates(from base: URL) -> [URL] {
        guard let origin = base.originURL else { return [] }
        var candidates: [URL] = []
        let path = base.discoveryPathComponent

        // Always prefer host-level well-known endpoints first
        if let hostLevelAS = URL(string: "/.well-known/oauth-authorization-server", relativeTo: origin) {
            candidates.append(hostLevelAS)
        }
        if let hostLevelOIDC = URL(string: "/.well-known/openid-configuration", relativeTo: origin) {
            candidates.append(hostLevelOIDC)
        }

        // Generate path-scoped variants only for non-Atlassian hosts
        let host = (base.host ?? "").lowercased()
        let allowPathScoped = !host.contains("atlassian")
        if allowPathScoped, !path.isEmpty {
            if let url = URL(string: "/.well-known/oauth-authorization-server\(path)", relativeTo: origin) {
                candidates.append(url)
            }
            if let url = URL(string: "/.well-known/openid-configuration\(path)", relativeTo: origin) {
                candidates.append(url)
            }
            if let url = URL(string: "\(path)/.well-known/openid-configuration", relativeTo: origin) {
                candidates.append(url)
            }
        }

        return dedupeURLs(candidates)
    }

    private func dedupeURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        for url in urls {
            let key = url.normalizedAbsoluteString
            if seen.insert(key).inserted {
                ordered.append(url)
            }
        }
        return ordered
    }

    private func fallbackBaseURL(for configuration: OAuthConfiguration, server: Server) -> URL? {
        if let authorizationOrigin = configuration.authorizationEndpoint?.originURL {
            return authorizationOrigin
        }
        if let resourceOrigin = configuration.resourceURI?.originURL {
            return resourceOrigin
        }
        if let baseString = server.baseURL, let baseURL = URL(string: baseString)?.originURL {
            return baseURL
        }
        return nil
    }

    private func rebuildEndpoint(_ url: URL, withBase base: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.scheme = baseComponents.scheme
        components.host = baseComponents.host
        components.port = baseComponents.port
        return components.url
    }

    private func shouldRetryWithFallback(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .cannotFindHost,
             .notConnectedToInternet,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    @MainActor
    func resetAuthorizationState(for server: Server, clearClient: Bool) {
        if clearClient {
            // Preserve manually-entered client credentials. Only clear if they
            // originated from dynamic registration (registrationEndpoint present)
            // and we are not using manual credentials.
            if let cfg = server.oauthConfiguration,
               cfg.registrationEndpoint != nil,
               !server.usesManualCredentials,
               cfg.clientSource == .dynamic {
                cfg.clientId = nil
                cfg.clientSecret = nil
            }
        }
        if let state = server.oauthState {
            state.serializedAuthState = Data()
            state.isActive = false
            state.lastTokenRefresh = nil
            state.providerMetadata = [:]
        }
        if server.oauthStatus != .error {
            server.oauthStatus = .unauthorized
        }
        OAuthDebugLogger.log("Reset OAuth state after failure",
                             category: "oauth.login",
                             server: server,
                             metadata: clearClient ? ["client_credentials": "cleared"] : nil)
        try? server.modelContext?.save()
    }

    private func formattedRegistrationFailureMessage(_ error: Error, registrationEndpoint: URL?) -> String {
        let base = error.localizedDescription
        guard case let OAuthServiceError.clientRegistrationFailed(statusCode, _) = error else { return base }
        switch statusCode {
        case 401:
            return "\(base). This provider may require manual OAuth client credentials."
        case 403:
            if registrationEndpoint?.host == "api.figma.com" {
                return "\(base). Figma restricts remote MCP OAuth registration to approved clients; see https://www.figma.com/mcp-catalog/."
            }
            return "\(base). This provider may block dynamic registration; try manual OAuth client credentials."
        default:
            return base
        }
    }

    /// Clears dynamic client credentials if the provider is known to require
    /// fresh registration (e.g., Atlassian) and we are not currently authorized.
    private func maybeClearStaleDynamicClientCredentials(server: Server,
                                                         configuration: OAuthConfiguration) {
        guard configuration.registrationEndpoint != nil,
              !server.usesManualCredentials,
              configuration.clientSource == .dynamic,
              server.oauthStatus != .authorized else { return }

        // Only clear credentials if we previously held an auth state (stale client).
        let hasPersistedState: Bool = {
            if let state = server.oauthState {
                return !state.serializedAuthState.isEmpty || state.isActive || state.lastTokenRefresh != nil
            }
            return false
        }()

        guard hasPersistedState else { return }

        if isAtlassianProvider(configuration) {
            if configuration.clientId != nil || configuration.clientSecret != nil {
                OAuthDebugLogger.log("Clearing dynamic client credentials before authorization",
                                     category: "oauth.registration",
                                     server: server,
                                     metadata: ["reason": "atlassian-re-register"])
            }
            configuration.clientId = nil
            configuration.clientSecret = nil
        }
    }

    private func isAtlassianProvider(_ configuration: OAuthConfiguration) -> Bool {
        func host(_ u: URL?) -> String { u?.host?.lowercased() ?? "" }
        let h1 = host(configuration.authorizationEndpoint)
        let h2 = host(configuration.tokenEndpoint)
        let h3 = host(configuration.registrationEndpoint)
        return h1.contains("mcp.atlassian.com") || h2.contains("atlassian") || h3.contains("atlassian")
    }

    private func persist(authState: OIDAuthState, for server: Server) {
        if server.oauthState == nil {
            server.oauthState = OAuthState(server: server)
        }
        guard let state = server.oauthState else { return }
        if let archived = Self.archiveAuthState(authState) {
            state.serializedAuthState = archived
        }
        state.isActive = true
        state.lastTokenRefresh = Date()
        server.oauthDiagnostics.lastErrorDescription = nil
        updateProviderMetadata(from: authState, for: server, category: "oauth.login")
        captureTokenTTL(from: authState, for: server, category: "oauth.login")
        if let accessToken = authState.lastTokenResponse?.accessToken {
            var tokenMetadata: [String: String] = [
                "access_token": OAuthDebugLogger.summarizeToken(accessToken)
            ]
            if let refreshToken = authState.lastTokenResponse?.refreshToken {
                tokenMetadata["refresh_token"] = OAuthDebugLogger.summarizeToken(refreshToken)
            }
            OAuthDebugLogger.log("Persisted OAuth tokens after authorization", category: "oauth.login", server: server, metadata: tokenMetadata)
        }
    }

    /// Extracts token expiry details from the last token response and
    /// (1) logs them for diagnostics and (2) persists them into providerMetadata.
    private func captureTokenTTL(from authState: OIDAuthState,
                                 for server: Server,
                                 category: String) {
        guard let response = authState.lastTokenResponse else { return }

        var ttl: [String: String] = [:]
        let isoFormatter = ISO8601DateFormatter()

        if let exp = response.accessTokenExpirationDate {
            ttl["access_expires_at"] = isoFormatter.string(from: exp)
            let remaining = max(0, exp.timeIntervalSinceNow)
            ttl["access_expires_in_sec"] = String(Int(remaining.rounded()))
            ttl["access_explicit_expiry"] = "true"
        } else {
            ttl["access_explicit_expiry"] = "false"
        }

        // Provider-specific refresh token hints from additional parameters
        if let additional = response.additionalParameters as? [String: Any], !additional.isEmpty {
            func number(from any: Any?) -> Int? {
                if let n = any as? NSNumber { return n.intValue }
                if let s = any as? String, let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
                return nil
            }
            func text(from any: Any?) -> String? {
                if let s = any as? String, !s.isEmpty { return s }
                if let n = any as? NSNumber { return n.stringValue }
                return nil
            }

            let rtSeconds = number(from: additional["refresh_token_expires_in"]) ??
                            number(from: additional["refresh_expires_in"]) ??
                            number(from: additional["rt_expires_in"]) ??
                            number(from: additional["refresh_token_ttl"]) // non-standard

            if let rtSeconds {
                let rtDate = Date().addingTimeInterval(TimeInterval(rtSeconds))
                ttl["refresh_expires_in_sec"] = String(rtSeconds)
                ttl["refresh_expires_at"] = isoFormatter.string(from: rtDate)
            } else if let at = text(from: additional["refresh_expires_at"]) ??
                                text(from: additional["refresh_token_expires_at"]) {
                ttl["refresh_expires_at"] = at
            }

            if let inactivity = number(from: additional["refresh_inactivity_window_sec"]) ??
                                 number(from: additional["offline_session_inactivity_timeout"]) {
                ttl["refresh_inactivity_window_sec"] = String(inactivity)
            }
        }

        guard !ttl.isEmpty else { return }

        if server.oauthState == nil { server.oauthState = OAuthState(server: server) }
        var metadata = server.oauthState?.providerMetadata ?? [:]
        metadata.removeValue(forKey: "access_marked_invalid")
        for (k, v) in ttl { metadata[k] = v }
        server.oauthState?.providerMetadata = metadata

        OAuthDebugLogger.log("Token TTL metadata", category: category, server: server, metadata: ttl)
    }

    private func updateProviderMetadata(from authState: OIDAuthState,
                                        for server: Server,
                                        category: String) {
        guard let additional = authState.lastTokenResponse?.additionalParameters,
              !additional.isEmpty else { return }

        var metadata: [String: String] = [:]
        for (key, value) in additional {
            metadata[key] = String(describing: value)
        }

        if server.oauthState == nil {
            server.oauthState = OAuthState(server: server)
        }
        server.oauthState?.providerMetadata = metadata

        OAuthDebugLogger.log("Token additional parameters", category: category, server: server, metadata: metadata)
    }

    func shouldRefreshAccessToken(for server: Server, skew: TimeInterval = 300) -> Bool {
        guard let metadata = server.oauthState?.providerMetadata else { return false }
        if metadata["access_marked_invalid"] == "true" {
            return true
        }
        guard let iso = metadata["access_expires_at"],
              let date = ISO8601DateFormatter().date(from: iso) else {
            return false
        }
        return date.timeIntervalSinceNow <= skew
    }

    func markAccessTokenInvalid(for server: Server) {
        guard let state = server.oauthState else { return }
        var metadata = state.providerMetadata
        metadata["access_marked_invalid"] = "true"
        state.providerMetadata = metadata
    }

    private func preferredLoopbackPort(for server: Server) -> UInt16 {
        var hasher = Hasher()
        hasher.combine(server.eventToken)
        let hash = hasher.finalize()
        let base: UInt16 = 42000
        let range: UInt16 = 2000
        let offset = UInt16(truncatingIfNeeded: hash) % range
        return base &+ offset
    }

}

// MARK: - Helper Models

struct ProtectedResourceMetadata: Decodable {
    let issuer: String?
    let authorizationServers: [URL]?
    let scopesSupported: [String]
    let registrationEndpoint: URL?
    let metadataVersion: String?
    let resource: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case registrationEndpoint = "registration_endpoint"
        case metadataVersion = "mcp_metadata_version"
        case resource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try container.decodeIfPresent(String.self, forKey: .issuer)
        authorizationServers = try container.decodeIfPresent([URL].self, forKey: .authorizationServers)
        scopesSupported = try container.decodeIfPresent([String].self, forKey: .scopesSupported) ?? []
        registrationEndpoint = try container.decodeIfPresent(URL.self, forKey: .registrationEndpoint)
        metadataVersion = try container.decodeIfPresent(String.self, forKey: .metadataVersion)
        resource = try container.decodeIfPresent(String.self, forKey: .resource)
    }
}

struct AuthorizationServerMetadata: Decodable {
    init(authorizationEndpoint: URL?,
         tokenEndpoint: URL?,
         registrationEndpoint: URL?,
         jwksURI: URL?,
         scopesSupported: [String],
         codeChallengeMethodsSupported: [String] = ["S256"],
         metadataVersion: String? = nil) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.jwksURI = jwksURI
        self.scopesSupported = scopesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.metadataVersion = metadataVersion
    }

    let authorizationEndpoint: URL?
    let tokenEndpoint: URL?
    let registrationEndpoint: URL?
    let jwksURI: URL?
    let scopesSupported: [String]
    let codeChallengeMethodsSupported: [String]
    let metadataVersion: String?

    var supportsS256PKCE: Bool {
        if codeChallengeMethodsSupported.isEmpty { return true }
        return codeChallengeMethodsSupported.contains { $0.caseInsensitiveCompare("S256") == .orderedSame }
    }

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case jwksURI = "jwks_uri"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case metadataVersion = "mcp_metadata_version"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationEndpoint = try container.decodeIfPresent(URL.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try container.decodeIfPresent(URL.self, forKey: .tokenEndpoint)
        registrationEndpoint = try container.decodeIfPresent(URL.self, forKey: .registrationEndpoint)
        jwksURI = try container.decodeIfPresent(URL.self, forKey: .jwksURI)
        scopesSupported = try container.decodeIfPresent([String].self, forKey: .scopesSupported) ?? []
        codeChallengeMethodsSupported = try container.decodeIfPresent([String].self, forKey: .codeChallengeMethodsSupported) ?? []
        metadataVersion = try container.decodeIfPresent(String.self, forKey: .metadataVersion)
    }
}

struct OAuthClientRegistrationRequest: Encodable {
    let redirectUris: [String]
    let tokenEndpointAuthMethod: String
    let grantTypes: [String]
    let responseTypes: [String]
    let clientName: String?
    let clientURI: String?
    let softwareId: String?
    let softwareVersion: String?

    enum CodingKeys: String, CodingKey {
        case redirectUris = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case clientName = "client_name"
        case clientURI = "client_uri"
        case softwareId = "software_id"
        case softwareVersion = "software_version"
    }
}

struct OAuthClientRegistrationResponse: Decodable {
    let clientId: String
    let clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

struct WWWAuthenticateHeader {
    let scheme: String
    let parameters: [String: String]

    var resource: URL? {
        guard let raw = parameters["resource"] else { return nil }
        return URL(string: raw)
    }

    var resourceMetadata: URL? {
        guard let raw = parameters["resource_metadata"] else { return nil }
        return URL(string: raw)
    }

    var scopes: [String] {
        guard let raw = parameters["scope"] else { return [] }
        return raw.split(separator: " ").map { String($0) }
    }

    static func parse(_ header: String?) -> WWWAuthenticateHeader? {
        guard let header, !header.isEmpty else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpace = trimmed.firstIndex(of: " ") else {
            return WWWAuthenticateHeader(scheme: trimmed, parameters: [:])
        }

        let scheme = String(trimmed[..<firstSpace])
        let parameterString = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
        var parameters: [String: String] = [:]

        for token in splitCommaSeparated(parameterString) {
            let pair = token.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            var value = pair[1]
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            parameters[key] = value
        }

        return WWWAuthenticateHeader(scheme: scheme, parameters: parameters)
    }

    private static func splitCommaSeparated(_ string: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuotes = false

        for character in string {
            switch character {
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "," where !inQuotes:
                results.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: true)
            default:
                current.append(character)
            }
        }

        if !current.isEmpty {
            results.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return results
    }
}

enum OAuthServiceError: Error, LocalizedError {
    case missingBaseURL
    case protectedResourceMetadataNotFound(candidates: [URL])
    case authorizationServerMetadataNotFound(candidates: [URL])
    case httpError(url: URL, statusCode: Int)
    case invalidResponse(url: URL)
    case decodingError(url: URL, underlying: Error)
    case missingRedirectURL
    case clientRegistrationFailed(statusCode: Int?, message: String)
    case clientRegistrationInvalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Remote server is missing a base URL for OAuth discovery."
        case let .protectedResourceMetadataNotFound(candidates):
            return "OAuth protected resource metadata not found for URLs: \(candidates.map { $0.absoluteString }.joined(separator: ", "))"
        case let .authorizationServerMetadataNotFound(candidates):
            return "OAuth authorization server metadata not found for URLs: \(candidates.map { $0.absoluteString }.joined(separator: ", "))"
        case let .httpError(url, status):
            return "Received HTTP \(status) while loading OAuth metadata from \(url.absoluteString)."
        case let .invalidResponse(url):
            return "Invalid response while loading OAuth metadata from \(url.absoluteString)."
        case let .decodingError(url, underlying):
            return "Failed to decode OAuth metadata from \(url.absoluteString): \(underlying.localizedDescription)"
        case .missingRedirectURL:
            return "Unable to construct OAuth redirect URI for this server."
        case let .clientRegistrationFailed(statusCode, message):
            if let statusCode {
                return "Client registration failed with HTTP \(statusCode): \(message)"
            } else {
                return "Client registration failed: \(message)"
            }
        case .clientRegistrationInvalidResponse:
            return "Client registration response did not include a client identifier."
        }
    }
}

// MARK: - URL helpers

private extension URL {
    var normalizedAbsoluteString: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return absoluteString
        }
        components.fragment = nil
        return components.string ?? absoluteString
    }

    var rootURL: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return nil }
        components.path = ""
        components.query = nil
        return components.url
    }

    var discoveryPathComponent: String {
        var trimmedPath = path
        if trimmedPath.isEmpty || trimmedPath == "/" {
            return ""
        }
        while trimmedPath.hasSuffix("/") {
            trimmedPath.removeLast()
        }
        if trimmedPath.isEmpty {
            return ""
        }
        if !trimmedPath.hasPrefix("/") {
            trimmedPath = "/" + trimmedPath
        }
        return trimmedPath
    }
}

private extension HTTPURLResponse {
    var headerFieldsAsStrings: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields {
            guard let keyString = key as? String else { continue }
            if let valueString = value as? String {
                result[keyString] = valueString
            } else {
                result[keyString] = String(describing: value)
            }
        }
        return result
    }
}

// MARK: - Auth state helpers

private extension OAuthService {
    nonisolated(unsafe) static func decodeAuthState(from data: Data) -> OIDAuthState? {
        guard !data.isEmpty else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        } catch {
            return nil
        }
    }

    nonisolated(unsafe) static func archiveAuthState(_ authState: OIDAuthState) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
    }

    private func recordDiagnostics(on server: Server?,
                                   url: URL,
                                   method: String,
                                   requestHeaders: [String: String]?,
                                   requestBodyPreview: String?,
                                   responseHeaders: [String: String]?,
                                   statusCode: Int?,
                                   message: String?,
                                   responseBodyPreview: String?) {
        guard let server else { return }
        var log = server.oauthDiagnostics
        log.recordAttempt(url: url,
                          httpMethod: method,
                          requestHeaders: requestHeaders,
                          requestBodyPreview: requestBodyPreview,
                          responseHeaders: responseHeaders,
                          statusCode: statusCode,
                          message: message,
                          responseBodyPreview: responseBodyPreview)
        server.oauthDiagnostics = log
    }

    private func sanitizedHeaders(_ headers: [String: String]) -> [String: String]? {
        guard !headers.isEmpty else { return nil }
        let redactedKeys: Set<String> = ["authorization", "cookie"]
        var sanitized: [String: String] = [:]
        for (key, value) in headers {
            if redactedKeys.contains(key.lowercased()) {
                sanitized[key] = "«redacted»"
            } else {
                sanitized[key] = value
            }
        }
        return sanitized.isEmpty ? nil : sanitized
    }

    private func makeRequestPreview(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return makeJSONPreview(from: data, redactingKeys: []) ?? makeRawStringPreview(from: data)
    }

    private func makeResponsePreview(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let sensitiveKeys: Set<String> = ["client_secret", "access_token", "refresh_token", "id_token"]
        return makeJSONPreview(from: data, redactingKeys: sensitiveKeys) ?? makeRawStringPreview(from: data)
    }

    private func makeJSONPreview(from data: Data, redactingKeys: Set<String>) -> String? {
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            let sanitized = sanitizeJSONValue(jsonObject, redactingKeys: redactingKeys)
            guard JSONSerialization.isValidJSONObject(sanitized) else {
                return nil
            }
            let sanitizedData = try JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
            guard let string = String(data: sanitizedData, encoding: .utf8) else { return nil }
            return truncatePreview(string)
        } catch {
            return nil
        }
    }

    private func sanitizeJSONValue(_ value: Any, redactingKeys: Set<String>) -> Any {
        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0, redactingKeys: redactingKeys) }
        }
        if let dictionary = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                if redactingKeys.contains(key.lowercased()) {
                    sanitized[key] = "«redacted»"
                } else {
                    sanitized[key] = sanitizeJSONValue(nestedValue, redactingKeys: redactingKeys)
                }
            }
            return sanitized
        }
        return value
    }

    private func makeRawStringPreview(from data: Data) -> String? {
        guard let string = String(data: data, encoding: .utf8) else {
            return "(\(data.count) bytes non-UTF8)"
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return truncatePreview(trimmed)
    }

    private func truncatePreview(_ string: String) -> String {
        let maxLength = 512
        if string.count > maxLength {
            let index = string.index(string.startIndex, offsetBy: maxLength)
            return String(string[..<index]) + "…"
        }
        return string
    }

    private func legacyAuthorizationMetadata(for configuration: OAuthConfiguration, server: Server) -> AuthorizationServerMetadata? {
        guard let origin = deriveOriginURL(from: configuration, server: server) else { return nil }
        let authorize = origin.appendingPathComponent("authorize")
        let token = origin.appendingPathComponent("token")
        return AuthorizationServerMetadata(
            authorizationEndpoint: authorize,
            tokenEndpoint: token,
            registrationEndpoint: nil,
            jwksURI: nil,
            scopesSupported: configuration.scopes,
            metadataVersion: OAuthConfiguration.defaultMetadataVersion
        )
    }

    private func deriveOriginURL(from configuration: OAuthConfiguration, server: Server) -> URL? {
        if let url = configuration.authorizationEndpoint?.originURL ?? configuration.tokenEndpoint?.originURL {
            return url
        }
        if let resource = configuration.resourceURI?.originURL {
            return resource
        }
        if let baseString = server.baseURL, let base = URL(string: baseString)?.originURL {
            return base
        }
        return nil
    }

}

private extension URL {
    var originURL: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

private extension OAuthServiceError {
    var httpStatusCode: Int? {
        if case let .httpError(_, status) = self {
            return status
        }
        return nil
    }
}
