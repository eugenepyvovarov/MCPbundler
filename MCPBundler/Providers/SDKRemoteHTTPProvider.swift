//
//  SDKRemoteHTTPProvider.swift
//  MCP Bundler
//
//  Provider for remote HTTP MCP servers
//

import Foundation
import MCP
import SwiftData
import Logging

enum OAuthRetryPolicy {
    static func isAuthenticationError(_ error: Error) -> Bool {
        if case let MCPError.internalError(detail) = error, detail == "Authentication required" {
            return true
        }
        if case let MCPError.transportError(underlying) = error,
           let urlError = underlying as? URLError,
           urlError.code == .userAuthenticationRequired {
            return true
        }
        return false
    }
}

final class SDKRemoteHTTPProvider: CapabilitiesProvider {
    private struct AuthChallengeState {
        var isHandling: Bool = false
        var lastHandledAt: Date?
    }

    private var pendingAuthChallenges: Set<String> = []
    private var authChallengeStates: [String: AuthChallengeState] = [:]
    private var authChallengeObserver: NSObjectProtocol?
    private let authChallengeDebounceInterval: TimeInterval = 8

    // Runtime connection (optional): when present, UpstreamProvider will reuse this client/transport
    private var runtimeClient: Client?
    private var runtimeTransport: HTTPClientTransport?
    private var runtimeInitialized = false

    @MainActor
    private func isRuntimeClient(_ client: Client) -> Bool {
        runtimeClient === client
    }

    @MainActor
    private func disconnectIfNeeded(client: Client, transport: HTTPClientTransport) async {
        if isRuntimeClient(client) { return }
        await client.disconnect()
        await transport.disconnect()
    }

    @MainActor
    private func clearRuntimeSession() {
        runtimeClient = nil
        runtimeTransport = nil
        runtimeInitialized = false
    }

    init() {
        authChallengeObserver = NotificationCenter.default.addObserver(forName: .oauthTransportAuthChallenge,
                                                                       object: nil,
                                                                       queue: nil) { [weak self] note in
            guard let self,
                  let serverID = note.userInfo?["serverID"] as? String else { return }
            Task { @MainActor in
                self.pendingAuthChallenges.insert(serverID)
            }
        }
    }

    deinit {
        if let observer = authChallengeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @MainActor
    func fetchCapabilities(for server: Server) async throws -> MCPCapabilities {
        guard let base = server.baseURL, let url = URL(string: base) else {
            throw CapabilityError.invalidConfiguration
        }

        let logAlias = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = normalizedAliasForLogs(logAlias)
        let compatCategory = "server.\(normalizedAlias).compat"

        func persistCompatLog(capability: String, method: String, error: MCPError) {
            guard let project = server.project, let context = project.modelContext else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let metadata = [
                "alias": logAlias,
                "alias_normalized": normalizedAlias,
                "capability": capability,
                "method": method,
                "error": error.localizedDescription
            ]
            let metadataData = try? encoder.encode(metadata)
            let message = "Advertised \(capability) but \(method) is missing (\(error.localizedDescription)). Treating \(capability) as empty."
            let entry = LogEntry(project: project,
                                 timestamp: Date(),
                                 level: .info,
                                 category: compatCategory,
                                 message: message,
                                 metadata: metadataData)
            context.insert(entry)
            try? context.save()
        }

        // Treat active OAuth state as requiring OAuth even if the explicit header binding is missing
        let hasOAuthHeaderBinding = server.headers.contains { $0.valueSource == .oauthAccessToken }
        let hasOAuthState = {
            guard let state = server.oauthState else { return false }
            return state.isActive && !state.serializedAuthState.isEmpty
        }()
        let requiresOAuth = hasOAuthHeaderBinding || hasOAuthState
        let streamingEndpoint = url.removingDefaultPort()

        enum StreamingFallbackError: Error {
            case requiresStreaming
        }

        func updateRemoteTransportMode(_ newMode: RemoteHTTPMode) {
            guard server.remoteHTTPMode != newMode else { return }
            server.remoteHTTPMode = newMode
            if let context = server.modelContext {
                try? context.save()
            }
        }

        func attempt(preferStreaming: Bool,
                     allowStreamingFallback: Bool) async throws -> MCPCapabilities {
            var headers: [String: String] = [:]
            let restEndpoint = streamingEndpoint
            let originHeader = Self.originHeader(for: server, fallback: streamingEndpoint)

            OAuthDebugLogger.log("Using REST endpoint",
                                 category: "oauth.capabilities",
                                 server: server,
                                 metadata: [
                                    "rest_endpoint": restEndpoint.absoluteString,
                                    "rest_source": "streamingPath"
                                 ])

            func log(_ message: String, metadata: [String: String]? = nil) {
                OAuthDebugLogger.log(message, category: "oauth.capabilities", server: server, metadata: metadata)
            }

            @MainActor
            func rebuildHeaders(forceOAuthRefresh: Bool) async {
                headers = await SDKRemoteHTTPProvider.refreshedHeaders(
                    for: server,
                    requiresOAuth: requiresOAuth,
                    forceRefresh: forceOAuthRefresh,
                    origin: originHeader,
                    includeAuthorizationBackfill: true,
                    logger: { message, metadata in
                        log(message, metadata: metadata)
                    }
                )
            }

            @MainActor
            func maybeHandlePendingAuthChallenge() async {
                guard requiresOAuth else { return }
                if beginAuthChallengeIfNeeded(for: server) {
                    log("Processing pending authentication challenge")
                    defer { completeAuthChallenge(for: server) }
                    await handleAuthenticationChallenge()
                }
            }

            await maybeHandlePendingAuthChallenge()
            await rebuildHeaders(forceOAuthRefresh: false)

            func makeTransport(streaming: Bool) -> HTTPClientTransport {
                let endpoint = streaming ? streamingEndpoint : restEndpoint
                return HTTPClientTransport(
                    endpoint: endpoint,
                    streaming: streaming,
                    requestModifier: { request in
                        var mutable = request
                        for (key, value) in headers {
                            mutable.setValue(value, forHTTPHeaderField: key)
                        }
                        return mutable
                    },
                    logger: Logger.oauthTransportLogger(for: server)
                )
            }

            @MainActor
            func handleAuthenticationChallenge() async {
                guard requiresOAuth else { return }
                log("Handling authentication challenge")
                OAuthService.shared.markAccessTokenInvalid(for: server)
                let refreshed = await OAuthService.shared.refreshAccessToken(for: server)
                if refreshed == nil {
                    await OAuthService.shared.runAuthDiscovery(server: server, wwwAuthenticate: nil)
                }
                await rebuildHeaders(forceOAuthRefresh: true)
                log("Authentication challenge handled")
            }

            let client = Client(name: "MCPBundler", version: "0.1.0", configuration: .strict)
            var transport = makeTransport(streaming: false)
            var usingStreamingTransport = false

            log("Connecting to remote server", metadata: [
                "streaming_endpoint": streamingEndpoint.absoluteString,
                "rest_candidate": restEndpoint.absoluteString,
                "requires_oauth": String(requiresOAuth)
            ])

            func connectWithRetry(streaming initialStreaming: Bool) async throws -> Initialize.Result {
                var streaming = initialStreaming
                var attempt = 0
                while true {
                    do {
                        await maybeHandlePendingAuthChallenge()
                        transport = makeTransport(streaming: streaming)

                        if streaming {
                            do {
                                try await transport.connect()
                            } catch {
                                await disconnectIfNeeded(client: client, transport: transport)
                                throw error
                            }
                        }

                        log("Starting initialize", metadata: ["streaming": String(streaming), "attempt": String(attempt + 1)])
                        let result = try await client.connect(transport: transport)
                        usingStreamingTransport = streaming
                        return result
                    } catch {
                        attempt += 1
                        await disconnectIfNeeded(client: client, transport: transport)
                        if requiresOAuth,
                           OAuthRetryPolicy.isAuthenticationError(error),
                           attempt <= 1 {
                            log("Authentication challenge detected during connect", metadata: ["attempt": String(attempt)])
                            OAuthService.shared.markAccessTokenInvalid(for: server)
                            await handleAuthenticationChallenge()
                            continue
                        }
                        log("Initialization failed", metadata: ["error": error.localizedDescription])
                        throw error
                    }
                }
            }

            func shouldFallbackToStreaming(_ error: Error) -> Bool {
                if case let MCPError.internalError(detail) = error,
                   detail == "Endpoint not found" || detail == "Method not allowed" {
                    return true
                }
                if case let MCPError.transportError(underlying) = error,
                   let urlError = underlying as? URLError,
                   urlError.code == .resourceUnavailable || urlError.code == .cannotParseResponse {
                    return true
                }
                return false
            }

            func connectStreaming(context: String,
                                   reason: StreamingFallbackDecision.Reason) async throws -> Initialize.Result {
                log("Opening SSE handshake", metadata: [
                    "context": context,
                    "reason": reason.rawValue
                ])

                let result = try await connectWithRetry(streaming: true)
                usingStreamingTransport = true
                return result
            }

            func connectHTTP(context: String,
                              reason: StreamingFallbackDecision.Reason,
                              fallbackMetadata: [String: String] = [:],
                              allowStreamingFallback: Bool) async throws -> Initialize.Result {
                do {
                    return try await connectWithRetry(streaming: false)
                } catch {
                    guard shouldFallbackToStreaming(error) else {
                        throw error
                    }
                    guard allowStreamingFallback else {
                        throw StreamingFallbackError.requiresStreaming
                    }
                    await disconnectIfNeeded(client: client, transport: transport)
                    var metadata: [String: String] = [
                        "context": context,
                        "error": error.localizedDescription,
                        "reason": reason.rawValue
                    ]
                    for (key, value) in fallbackMetadata {
                        metadata[key] = value
                    }
                    log("Retrying initialize with SSE", metadata: metadata)
                    return try await connectStreaming(context: context, reason: reason)
                }
            }

            func connectUsingHTTPFirstFallback(context: String,
                                               forceStreaming: Bool = false,
                                               allowStreamingFallback: Bool) async throws -> Initialize.Result {
                let decision = StreamingFallbackDecision.decide(usingStreaming: usingStreamingTransport,
                                                                forceStreaming: forceStreaming)

                switch decision.action {
                case .reuseStreaming:
                    log("Switching to streaming transport for fallback", metadata: [
                        "context": context,
                        "reason": decision.reason.rawValue
                    ])
                    return try await connectStreaming(context: context, reason: decision.reason)
                case .httpFirst:
                    return try await connectHTTP(context: context,
                                                 reason: decision.reason,
                                                 fallbackMetadata: [:],
                                                 allowStreamingFallback: allowStreamingFallback)
                }
            }

            func describeCurrentEndpoint(action: String) async {
                log("Using REST endpoint", metadata: [
                    "context": action,
                    "rest_endpoint": restEndpoint.absoluteString,
                    "rest_source": "streamingPath"
                ])
            }

            func performRequestWithRetry<T>(_ actionName: String,
                                             allowStreamingFallback: Bool,
                                             action: () async throws -> T) async throws -> T {
                var attempt = 0
                while true {
                    do {
                        await maybeHandlePendingAuthChallenge()
                        await rebuildHeaders(forceOAuthRefresh: false)
                        log("Performing request", metadata: [
                            "attempt": String(attempt + 1),
                            "context": actionName
                        ])
                        await describeCurrentEndpoint(action: actionName)
                        let result = try await action()
                        log("Request succeeded", metadata: [
                            "context": actionName,
                            "attempt": String(attempt + 1)
                        ])
                        return result
                    } catch {
                        attempt += 1
                        if requiresOAuth,
                           OAuthRetryPolicy.isAuthenticationError(error),
                           attempt <= 1 {
                            await disconnectIfNeeded(client: client, transport: transport)
                            log("Authentication challenge detected during request", metadata: [
                                "attempt": String(attempt),
                                "context": actionName
                            ])
                            OAuthService.shared.markAccessTokenInvalid(for: server)
                            await handleAuthenticationChallenge()
                            _ = try await connectUsingHTTPFirstFallback(context: actionName,
                                                                         allowStreamingFallback: allowStreamingFallback)
                            continue
                        }
                        if shouldFallbackToStreaming(error), !usingStreamingTransport {
                            log("Request triggered SSE fallback", metadata: [
                                "context": actionName,
                                "attempt": String(attempt),
                                "error": error.localizedDescription
                            ])
                            log("Fallback state before streaming connect", metadata: [
                                "context": actionName,
                                "using_streaming": String(usingStreamingTransport)
                            ])
                            guard allowStreamingFallback else {
                                throw StreamingFallbackError.requiresStreaming
                            }
                            updateRemoteTransportMode(.httpWithSSE)
                            _ = try await connectUsingHTTPFirstFallback(context: actionName,
                                                                         forceStreaming: true,
                                                                         allowStreamingFallback: allowStreamingFallback)
                            log("Fallback completed", metadata: [
                                "context": actionName,
                                "using_streaming": String(usingStreamingTransport)
                            ])
                            continue
                        }
                        log("Request failed", metadata: [
                            "error": error.localizedDescription,
                            "context": actionName,
                            "attempt": String(attempt),
                            "error_type": String(reflecting: error)
                        ])
                        throw error
                    }
                }
            }

            do {
                let initResult: Initialize.Result
                if preferStreaming {
                    initResult = try await connectStreaming(context: "initialize", reason: .alreadyStreaming)
                    updateRemoteTransportMode(.httpWithSSE)
                } else {
                    initResult = try await connectUsingHTTPFirstFallback(context: "initialize",
                                                                         allowStreamingFallback: allowStreamingFallback)
                }

                var toolsDTO: [MCPTool] = []
                var resourcesDTO: [MCPResource] = []
                var promptsDTO: [MCPPrompt] = []

            if initResult.capabilities.tools != nil {
                let (tools, _) = try await performRequestWithRetry("tools.list",
                                                                    allowStreamingFallback: allowStreamingFallback) {
                    try await client.listTools()
                }
                log("Fetched tools", metadata: ["count": String(tools.count)])
                toolsDTO = tools.map { tool in
                    let annotations: Tool.Annotations? = tool.annotations.isEmpty ? nil : tool.annotations
                    return MCPTool(
                        name: tool.name,
                        description: tool.description,
                        inputSchema: tool.inputSchema
                    )
                }
            }
            if initResult.capabilities.resources != nil {
                do {
                    let (resources, _) = try await performRequestWithRetry("resources.list",
                                                                           allowStreamingFallback: allowStreamingFallback) {
                        try await client.listResources()
                    }
                    log("Fetched resources", metadata: ["count": String(resources.count)])
                    resourcesDTO = resources.map { MCPResource(name: $0.name, uri: $0.uri, description: $0.description) }
                } catch let mcpError as MCPError {
                    if case .methodNotFound = mcpError {
                        persistCompatLog(capability: "resources", method: "resources/list", error: mcpError)
                    } else {
                        throw mcpError
                    }
                }
            }
            if initResult.capabilities.prompts != nil {
                do {
                    let (prompts, _) = try await performRequestWithRetry("prompts.list",
                                                                          allowStreamingFallback: allowStreamingFallback) {
                        try await client.listPrompts()
                    }
                    log("Fetched prompts", metadata: ["count": String(prompts.count)])
                    promptsDTO = prompts.map { MCPPrompt(name: $0.name, description: $0.description) }
                } catch let mcpError as MCPError {
                    if case .methodNotFound = mcpError {
                        persistCompatLog(capability: "prompts", method: "prompts/list", error: mcpError)
                    } else {
                        throw mcpError
                    }
                }
            }

                            await disconnectIfNeeded(client: client, transport: transport)

                log("Capability fetch completed", metadata: [
                    "tools": String(toolsDTO.count),
                    "resources": resourcesDTO.isEmpty ? "0" : String(resourcesDTO.count),
                    "prompts": promptsDTO.isEmpty ? "0" : String(promptsDTO.count)
                ])

                updateRemoteTransportMode(usingStreamingTransport ? .httpWithSSE : .httpOnly)

                return MCPCapabilities(
                    serverName: initResult.serverInfo.name,
                    serverDescription: initResult.instructions,
                    tools: toolsDTO,
                    resources: resourcesDTO.isEmpty ? nil : resourcesDTO,
                    prompts: promptsDTO.isEmpty ? nil : promptsDTO
                )
            } catch {
                await disconnectIfNeeded(client: client, transport: transport)
                log("Capability fetch failed", metadata: ["error": error.localizedDescription])
                throw error
            }
        }

        let preferStreaming = server.remoteHTTPMode == .httpWithSSE
        let allowStreamingFallback = !preferStreaming
        do {
            return try await attempt(preferStreaming: preferStreaming,
                                     allowStreamingFallback: allowStreamingFallback)
        } catch StreamingFallbackError.requiresStreaming {
            updateRemoteTransportMode(.httpWithSSE)
            return try await attempt(preferStreaming: true,
                                     allowStreamingFallback: true)
        }
    }
}

private extension URL {
    func removingDefaultPort() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        if let port = components.port,
           let scheme = components.scheme?.lowercased(),
           (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
            components.port = nil
            if let normalized = components.url {
                return normalized
            }
        }
        return self
    }
}

extension SDKRemoteHTTPProvider {
    @MainActor
    static func refreshedHeaders(for server: Server,
                                 requiresOAuth: Bool,
                                 forceRefresh: Bool,
                                 origin: String,
                                 includeAuthorizationBackfill: Bool,
                                 logger: ((String, [String: String]?) -> Void)? = nil) async -> [String: String] {
        if requiresOAuth {
            let needsRefresh = forceRefresh || OAuthService.shared.shouldRefreshAccessToken(for: server)
            if needsRefresh {
                _ = await OAuthService.shared.refreshAccessToken(for: server)
            }
        }

        var headers = buildHeaders(for: server)
        headers["Origin"] = origin

        if includeAuthorizationBackfill {
            let hasAuthHeader = headers.keys.contains {
                $0.caseInsensitiveCompare("Authorization") == .orderedSame
            }
            if !hasAuthHeader,
               let token = OAuthService.shared.resolveAccessToken(for: server),
               !token.isEmpty {
                if token.lowercased().hasPrefix("bearer ") {
                    headers["Authorization"] = token
                } else {
                    headers["Authorization"] = "Bearer \(token)"
                }
            }
        }

        if server.isOAuthDebugLoggingEnabled, let logger {
            let summarized = headers.map { key, value -> String in
                if key.caseInsensitiveCompare("Authorization") == .orderedSame {
                    let token = value.replacingOccurrences(of: "Bearer ", with: "")
                    return "Authorization=Bearer \(OAuthDebugLogger.summarizeToken(token))"
                }
                return "\(key)=\(value)"
            }.joined(separator: ", ")

            var metadata: [String: String] = ["headers": summarized]
            if let rawAuth = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })?.value {
                metadata["authorization_raw"] = rawAuth
            }
            logger("Updated request headers", metadata)
        }

        return headers
    }

    static func originHeader(for server: Server, fallback: URL) -> String {
        OAuthConstants.clientOrigin
    }

    func serverIdentifier(for server: Server) -> String {
        String(describing: server.persistentModelID)
    }

    @MainActor
    func beginAuthChallengeIfNeeded(for server: Server) -> Bool {
        if server.oauthStatus == .refreshing { return false }

        let key = serverIdentifier(for: server)
        var state = authChallengeStates[key] ?? AuthChallengeState()
        if state.isHandling { return false }

        let now = Date()
        if let last = state.lastHandledAt,
           now.timeIntervalSince(last) < authChallengeDebounceInterval {
            return false
        }

        let metadataInvalid = server.oauthState?.providerMetadata["access_marked_invalid"] == "true"
        let hasPendingSignal = pendingAuthChallenges.contains(key)
        guard metadataInvalid || hasPendingSignal else { return false }

        pendingAuthChallenges.remove(key)
        state.isHandling = true
        authChallengeStates[key] = state
        return true
    }

    @MainActor
    func completeAuthChallenge(for server: Server) {
        let key = serverIdentifier(for: server)
        var state = authChallengeStates[key] ?? AuthChallengeState()
        state.isHandling = false
        state.lastHandledAt = Date()
        authChallengeStates[key] = state
    }
}

// MARK: - Runtime client exposure for reuse by UpstreamProvider

extension SDKRemoteHTTPProvider: ExposesClient {
    @MainActor
    func connectAndReturnClient(for server: Server) async throws -> MCP.Client {
        if let existing = runtimeClient, runtimeInitialized { return existing }

        guard let base = server.baseURL, let url = URL(string: base) else {
            throw CapabilityError.invalidConfiguration
        }

        // Build headers similarly to capability fetch path
        let requiresOAuth = server.headers.contains { $0.valueSource == .oauthAccessToken } || {
            guard let state = server.oauthState else { return false }
            return state.isActive && !state.serializedAuthState.isEmpty
        }()

        var headers: [String: String] = [:]
        let streamingEndpoint = url.removingDefaultPort()
        let originHeader = Self.originHeader(for: server, fallback: streamingEndpoint)

        @MainActor
        func rebuildHeaders(forceOAuthRefresh: Bool) async {
            headers = await SDKRemoteHTTPProvider.refreshedHeaders(
                for: server,
                requiresOAuth: requiresOAuth,
                forceRefresh: forceOAuthRefresh,
                origin: originHeader,
                includeAuthorizationBackfill: true,
                logger: { message, metadata in
                    OAuthDebugLogger.log(message,
                                         category: "oauth.capabilities",
                                         server: server,
                                         metadata: metadata)
                }
            )
        }

        @MainActor
        func handleAuthenticationChallenge() async {
            guard requiresOAuth else { return }
            OAuthService.shared.markAccessTokenInvalid(for: server)
            let refreshed = await OAuthService.shared.refreshAccessToken(for: server)
            if refreshed == nil {
                await OAuthService.shared.runAuthDiscovery(server: server, wwwAuthenticate: nil)
            }
            await rebuildHeaders(forceOAuthRefresh: true)
        }

        @MainActor
        func maybeHandlePendingAuthChallenge() async {
            guard requiresOAuth else { return }
            if beginAuthChallengeIfNeeded(for: server) {
                OAuthDebugLogger.log("Processing pending authentication challenge",
                                     category: "oauth.runtime",
                                     server: server)
                defer { completeAuthChallenge(for: server) }
                await handleAuthenticationChallenge()
            }
        }

        await maybeHandlePendingAuthChallenge()
        await rebuildHeaders(forceOAuthRefresh: false)
        let restEndpoint = streamingEndpoint

        func makeTransport(streaming: Bool) -> HTTPClientTransport {
            let endpoint = streaming ? streamingEndpoint : restEndpoint
            return HTTPClientTransport(
                endpoint: endpoint,
                streaming: streaming,
                requestModifier: { req in
                    var mutable = req
                    for (k, v) in headers {
                        mutable.setValue(v, forHTTPHeaderField: k)
                    }
                    return mutable
                },
                logger: Logger.oauthTransportLogger(for: server)
            )
        }

        let client = Client(name: "MCPBundler", version: "0.1.0", configuration: .strict)
        var attempt = 0
        while true {
            clearRuntimeSession()
            await maybeHandlePendingAuthChallenge()
            var wantsStreaming = server.remoteHTTPMode != .httpOnly
            var transport = makeTransport(streaming: wantsStreaming)
            do {
                if wantsStreaming {
                    try await transport.connect()
                }
                _ = try await client.connect(transport: transport)
                runtimeClient = client
                runtimeTransport = transport
                runtimeInitialized = true
                server.remoteHTTPMode = wantsStreaming ? .httpWithSSE : .httpOnly
                try? server.modelContext?.save()
                return client
            } catch {
                await disconnectIfNeeded(client: client, transport: transport)
                clearRuntimeSession()

                if OAuthRetryPolicy.isAuthenticationError(error) && attempt == 0 {
                    OAuthService.shared.markAccessTokenInvalid(for: server)
                    let refreshed = await OAuthService.shared.refreshAccessToken(for: server)
                    if refreshed != nil {
                        await rebuildHeaders(forceOAuthRefresh: true)
                        attempt += 1
                        continue
                    }
                    server.oauthStatus = .unauthorized
                    clearRuntimeSession()
                    throw CapabilityError.executionFailed("Authentication required")
                }

                // Allow HTTP-only fallback only for non-Atlassian hosts
                if (url.host?.lowercased().contains("atlassian") ?? false) {
                    clearRuntimeSession()
                    throw error
                }

                await rebuildHeaders(forceOAuthRefresh: false)
                let http = makeTransport(streaming: false)
                do {
                    _ = try await client.connect(transport: http)
                    runtimeClient = client
                    runtimeTransport = http
                    runtimeInitialized = true
                    server.remoteHTTPMode = .httpOnly
                    try? server.modelContext?.save()
                    return client
                } catch {
                    await disconnectIfNeeded(client: client, transport: http)
                    clearRuntimeSession()
                    throw error
                }
            }
        }
    }

    @MainActor
    func awaitHintIfNeeded(timeout: TimeInterval) async -> Bool {
        runtimeInitialized
    }

    @MainActor
    func resetRuntimeSession() async {
        guard let client = runtimeClient, let transport = runtimeTransport else { return }
        await client.disconnect()
        await transport.disconnect()
        runtimeClient = nil
        runtimeTransport = nil
        runtimeInitialized = false
    }
}

private func normalizedAliasForLogs(_ alias: String) -> String {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "unnamed" }
    return trimmed.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
}

struct StreamingFallbackDecision {
    enum Reason: String {
        case forced
        case alreadyStreaming
        case httpFirst
    }

    enum Action {
        case reuseStreaming
        case httpFirst
    }

    let action: Action
    let reason: Reason

    static func decide(usingStreaming: Bool,
                       forceStreaming: Bool) -> StreamingFallbackDecision {
        if usingStreaming {
            return StreamingFallbackDecision(action: .reuseStreaming, reason: .alreadyStreaming)
        }
        if forceStreaming {
            return StreamingFallbackDecision(action: .reuseStreaming, reason: .forced)
        }
        return StreamingFallbackDecision(action: .httpFirst, reason: .httpFirst)
    }
}
