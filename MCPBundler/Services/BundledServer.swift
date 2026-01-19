//
//  BundledServer.swift
//  MCP Bundler
//
//  MCP server that exposes the active project's aggregated capabilities
//  and routes calls to upstream servers via providers.
//

import Foundation
import MCP
import SwiftData
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private enum ContextOptimizationTools {
    static let searchName = "search_tool"
    static let callName = "call_tool"
    static let searchTitle = "Search Tools"
    static let searchDescription = "Search the bundled servers and skills to discover available tools."
    static let callTitle = "Call Tool"
    static let callDescription = "Invoke a namespaced tool (alias__tool) with optional arguments."
    static let searchSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Optional substring to match within tool titles, descriptions, or names.")
            ])
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false)
    ])
    static let callSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "tool_name": .object([
                "type": .string("string"),
                "description": .string("Namespaced tool identifier (alias__tool).")
            ]),
            "arguments": .object([
                "type": .string("object"),
                "description": .string("JSON object passed through as tool arguments.")
            ])
        ]),
        "required": .array([.string("tool_name")]),
        "additionalProperties": .bool(false)
    ])
}

enum SkillsInstructionCopy {
    // Copy defined in docs/skills.md (rev 2025-11-19, MCP baseline 2025-06-18)
    static let skillsUsageText = """
    This response contains expert instructions:
    1. Read the full guidance before acting.
    2. Understand your original task, any allowed-tools hints, and the resource list.
    3. Apply the workflow with your own judgment - skills don't execute steps for you.
    4. Access referenced files via MCP resources/list + resources/read. If your client lacks MCP resource support, call fetch_resource with the provided URI.
    5. Respect any constraints or best practices the skill specifies.
    """

    static func skillInstructionPreamble(displayName: String) -> String {
        "[Skill Notice] The following guidance is authored by the \"\(displayName)\" skill. Load only the files it references (via MCP resources or fetch_resource if your client lacks resources/read) and apply the instructions with your own tools."
    }
}

// Helper to convert MCP Value to standard JSON
extension Value {
    nonisolated(unsafe) func toStandardJSON() -> Any {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .null:
            return NSNull()
        case .array(let value):
            return value.map { $0.toStandardJSON() }
        case .object(let value):
            var result: [String: Any] = [:]
            for (key, val) in value {
                result[key] = val.toStandardJSON()
            }
            return result
        case .data(mimeType: _, _):
            return NSNull() // or handle appropriately
        }
    }

    // Convert Value back from standard JSON
    nonisolated(unsafe) static func fromStandardJSON(_ json: Any) -> Value {
        switch json {
        case let str as String:
            return .string(str)
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            return .array(array.map { fromStandardJSON($0) })
        case let dict as [String: Any]:
            var result: [String: Value] = [:]
            for (key, val) in dict {
                result[key] = fromStandardJSON(val)
            }
            return .object(result)
        default:
            return .null
        }
    }
}

// MARK: - One-shot tool-call retry on endpoint discovery (file-scope helper)
@MainActor
private func callToolWithSingleRetry(upstream: UpstreamProvider?,
                                     client: MCP.Client,
                                     name: String,
                                     arguments: [String: Value]?) async throws -> ([Tool.Content], Bool?) {
    do {
        return try await client.callTool(name: name, arguments: arguments)
    } catch let error as MCPError {
        if case let MCPError.internalError(detail) = error,
           (detail == "Endpoint not found" || detail == "Client connection not initialized") {
            await upstream?.resetAfterFailure()
            let freshClient = try await upstream!.ensureClient()
            return try await freshClient.callTool(name: name, arguments: arguments)
        } else if case let MCPError.internalError(detail) = error, detail == "Authentication required" {
            // Refresh OAuth and reconnect once, then retry
            await upstream?.handleAuthenticationChallenge()
            await upstream?.resetAfterFailure()
            let freshClient = try await upstream!.ensureClient()
            return try await freshClient.callTool(name: name, arguments: arguments)
        }
        throw error
    } catch {
        throw error
    }
}

@MainActor
protocol UpstreamProviding: AnyObject {
    var alias: String { get }
    var shouldKeepConnectionWarm: Bool { get }
    var serverIdentifier: PersistentIdentifier? { get }
    var currentOAuthStatus: OAuthStatus? { get }
    func update(server: MCPBundler.Server, provider: any CapabilitiesProvider) async -> Bool
    func synchronize(server: MCPBundler.Server, provider: any CapabilitiesProvider)
    func ensureClient() async throws -> MCP.Client
    func ensureWarmConnection() async throws
    // Optional: wait for remote readiness; default no-op
    func awaitHintIfNeeded(timeout: TimeInterval) async
    // Optional: OAuth auth-challenge handling
    func handleAuthenticationChallenge() async
    // Optional: expose provider-specific runtime client helpers
    func exposedClientProvider() -> ExposesClient?
    func resetAfterFailure() async
    func disconnect(reason: UpstreamDisconnectReason) async
}

@MainActor
extension UpstreamProviding {
    func awaitHintIfNeeded(timeout: TimeInterval = 0) async { /* no-op by default */ }
    func handleAuthenticationChallenge() async { /* no-op by default */ }
    func exposedClientProvider() -> ExposesClient? { nil }
    var currentOAuthStatus: OAuthStatus? { nil }
}

enum UpstreamDisconnectReason: String {
    case configurationChanged
    case removed
    case manual
    case failure
}

@MainActor
final class BundledServerManager {
    typealias LogSink = @MainActor (LogLevel, String, String) async -> Void
    typealias ProviderFactory = @MainActor (MCPBundler.Server, any CapabilitiesProvider, @escaping LogSink) -> UpstreamProviding

    private let providerFactory: ProviderFactory
    private let customWarmUpHandler: (@MainActor ([UpstreamProviding]) async -> Void)?
    private var server: MCP.Server?
    private var snapshot: BundlerAggregator.Snapshot?
    private var activeClientInfo: MCP.Client.Info?
    private var logProject: Project?
    private var logProjectID: PersistentIdentifier?
    private var logProjectToken: UUID?
    private var persistenceContext: ModelContext?
    private var pendingLogEntries: [LogEntry] = []
    private var isStarted = false
    private let logSaveBatchSize = 25
    private let logSaveInterval: TimeInterval = 5
    private let logRetentionLimit = 5000
    private var pendingSaveCount = 0
    private var lastSaveDate: Date = Date()
    private var restartingAliases: Set<String> = []
    private var warmUpTask: Task<Void, Never>?
    private var hasLoggedProjectRehydrationFailure = false
    private let listChangedNotificationsEnabled: Bool
    private var lastAnnouncedSnapshotRevision: Int64?
    private var lastAnnouncedProjectID: PersistentIdentifier?
    private let skillsAlias = SkillsCapabilitiesBuilder.alias
    private static let fetchTempFileToolName = "fetch_temp_file"
    private static let fetchTempFileToolTitle = "Fetch Temporary File"
    private static let fetchTempFileToolDescription = "Read UTF-8 files the bundler wrote into the temporary directory (/tmp or /var/folders) when large tool responses are spilled (optionally provide offset/length to fetch a chunk)."
    private static let fetchTempFileSearchAlias = "mcpbundler"
    private static let fetchTempFileSearchDescription = "Return the UTF-8 contents of bundler-spilled /tmp or /var/folders files (supports optional offset/length)."
    private static let fetchTempFileMaxBytes: UInt64 = 2 * 1024 * 1024
    private static let fetchTempFileInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Absolute file path under /tmp or /var/folders written by MCP Bundler when storing large responses.")
            ]),
            "offset": .object([
                "type": .string("integer"),
                "minimum": .int(0),
                "description": .string("Optional character offset (>= 0) for chunked reads.")
            ]),
            "length": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "description": .string("Optional character length (>= 1) limiting chunk size.")
            ])
        ]),
        "required": .array([.string("path")]),
        "additionalProperties": .bool(false)
    ])
    private static let fetchTempFileAllowedPrefixes: [String] = [
        "/tmp",
        "/private/tmp",
        "/var/folders",
        "/private/var/folders"
    ]
    private let skillsLibrary: SkillsLibraryService
    private var skillsLibraryLoaded = false
    private var contextOptimizationsEnabled = false
    private var hideSkillsForNativeClientsEnabled = false
    private var storeLargeResponsesAsFiles = false
    private var largeResponseThreshold = Project.defaultLargeToolResponseThreshold
    private var projectSlugForLargeResponses = "project"
    private var tempResources: [String: TempResource] = [:]
    private var tempResourceOrder: [String] = []
    private let tempResourceLimit = 64
    private let temporaryDirectoryProvider: @Sendable () -> URL
    private struct TempResource {
        let path: String
        let mimeType: String
        let displayName: String
        let createdAt: Date
    }
    private struct TempFileDescriptor {
        let path: String
        let mimeType: String
        let fileName: String
        let byteCount: UInt64
    }

    init(providerFactory: @escaping ProviderFactory = BundledServerManager.defaultProviderFactory,
         warmUpHandler: (@MainActor ([UpstreamProviding]) async -> Void)? = nil,
         temporaryDirectoryProvider: @escaping @Sendable () -> URL = { FileManager.default.temporaryDirectory },
         skillsLibrary: SkillsLibraryService = SkillsLibraryService(),
         listChangedNotificationsEnabled: Bool = false) {
        self.providerFactory = providerFactory
        self.customWarmUpHandler = warmUpHandler
        self.temporaryDirectoryProvider = temporaryDirectoryProvider
        self.skillsLibrary = skillsLibrary
        self.listChangedNotificationsEnabled = listChangedNotificationsEnabled
    }

    func start(project: Project,
               snapshot: BundlerAggregator.Snapshot,
               providers: [MCPBundler.Server: any CapabilitiesProvider]) async throws {
        guard !isStarted else {
            return
        }

        activeClientInfo = nil

        // Register upstream providers for routing
        let warmTargets = await updateProviderRegistry(providers)
        scheduleWarmUp(for: warmTargets)
        updateProviderDescriptors(with: providers)
        clearTempResources()
        self.snapshot = snapshot
        lastAnnouncedSnapshotRevision = project.snapshotRevision
        lastAnnouncedProjectID = project.persistentModelID
        applyProjectRuntimeSettings(from: project)
        updateLogProjectReference(with: project)
        self.pendingSaveCount = 0
        self.lastSaveDate = Date()
        await refreshSkillsLibrary(reason: "snapshot reload")
        await refreshSkillsLibrary(reason: "startup")

        // Build server capabilities based on snapshot
        var caps = MCP.Server.Capabilities()
        caps.tools = .init(listChanged: true)
        caps.prompts = .init(listChanged: true)
        caps.resources = .init(subscribe: false, listChanged: true)

        let mcpServer = MCP.Server(
            name: "MCPBundler",
            version: "0.1.0",
            capabilities: caps
        )
        isStarted = true

        // Register handlers
        // Tools list
        await mcpServer.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return .init(tools: []) }
            await self.log(level: .info, category: "mcp-request", message: "tools/list", metadata: nil)
            guard let snap = await self.ensureSnapshotReady() else {
                await self.log(level: .error, category: "mcp-error", message: "tools/list failed: No snapshot available", metadata: nil)
                return .init(tools: [])
            }

            let hiddenSkillSlugs = await MainActor.run { self.hiddenSkillSlugsForActiveClient() }
            let visibleTools = NativeSkillsVisibilityFilter.filterTools(snap.tools, hiddenSkillSlugs: hiddenSkillSlugs)

            let useContextOptimizations = await MainActor.run { self.contextOptimizationsEnabled }
            if useContextOptimizations {
                let includesSkills = visibleTools.contains { tool in
                    tool.alias == SkillsCapabilitiesBuilder.alias &&
                        tool.original != SkillsCapabilitiesBuilder.compatibilityToolName
                }
                let tools = contextOptimizationTools(availableTools: visibleTools,
                                                     includeSkillsInDescription: includesSkills)
                return .init(tools: tools)
            }

            var tools = visibleTools.map { entry -> Tool in
                let annotations: Tool.Annotations = entry.annotations ?? entry.title.map { Tool.Annotations(title: $0) } ?? nil

                // Use the input schema from the database entry
                let schema: Value
                if let inputSchema = entry.inputSchema {
                    // Convert to standard JSON and back to ensure proper serialization
                    let standardJSON = inputSchema.toStandardJSON()
                    schema = Value.fromStandardJSON(standardJSON)
                } else {
                    schema = .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([]),
                        "additionalProperties": .bool(false)
                    ])
                }

                return Tool(
                    name: entry.namespaced,
                    description: entry.description ?? "",
                    inputSchema: schema,
                    annotations: annotations
                )
            }

            tools.append(self.fetchTempFileToolDescriptor())

            // Return tools list
            return .init(tools: tools)
        }

        // Tool call
        await mcpServer.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return .init(content: [.text("Bundler not ready")], isError: true)
            }
            let name = params.name
            await self.log(level: .info, category: "mcp-request", message: "tools/call", metadata: nil)
            let argsDetails = indentLines(describeArguments(params.arguments))
            let detailMessage = "tool: \(name)\nargs:\n\(argsDetails)"
            await self.log(level: .info, category: "mcp-request-detail", message: detailMessage, metadata: nil)

            guard let snap = await self.ensureSnapshotReady() else {
                await self.log(level: .error, category: "mcp-error", message: "tools/call failed: Bundler not ready", metadata: nil)
                return .init(content: [.text("Bundler not ready")], isError: true)
            }

            let useContextOptimizations = await MainActor.run { self.contextOptimizationsEnabled }
            if useContextOptimizations {
                if name == ContextOptimizationTools.searchName {
                    return await self.handleSearchTool(arguments: params.arguments, snapshot: snap)
                } else if name == ContextOptimizationTools.callName {
                    return await self.handleMetaToolCall(arguments: params.arguments, snapshot: snap)
                }
            }

            return await self.routeToolCall(named: name,
                                            arguments: params.arguments,
                                            snapshot: snap)
        }

        // Resources list
        await mcpServer.withMethodHandler(ListResources.self) { [weak self] _ in
            guard let self else { return .init(resources: [], nextCursor: nil) }
            await self.log(level: .info, category: "mcp-request", message: "resources/list", metadata: nil)
            guard let snap = await self.ensureSnapshotReady() else {
                await self.log(level: .error, category: "mcp-error", message: "resources/list failed: No snapshot available", metadata: nil)
                return .init(resources: [], nextCursor: nil)
            }
            let hiddenSkillSlugs = await MainActor.run { self.hiddenSkillSlugsForActiveClient() }
            let resources = NativeSkillsVisibilityFilter.filterResources(snap.resources, hiddenSkillSlugs: hiddenSkillSlugs)
            let wrapped = resources.map { Resource(name: $0.name, uri: $0.uri, description: $0.description) }
            return .init(resources: wrapped, nextCursor: nil)
        }

        // Resource read
        await mcpServer.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self else { return .init(contents: []) }
            await self.log(level: .info, category: "mcp-request", message: "resources/read", metadata: nil)
            await self.log(level: .info, category: "mcp-request-detail", message: "uri: (params.uri)", metadata: nil)
            guard let snap = await self.ensureSnapshotReady() else {
                await self.log(level: .error, category: "mcp-error", message: "resources/read failed: No snapshot available", metadata: nil)
                return .init(contents: [])
            }
            if let tempResource = await MainActor.run(body: { self.tempResources[params.uri] }) {
                return await self.serveTempResource(uri: params.uri, resource: tempResource)
            }
            guard let unwrap = BundlerURI.unwrap(params.uri) else { return .init(contents: []) }
            guard let _ = snap.resourceMap[params.uri] else { return .init(contents: []) }
            if unwrap.alias == self.skillsAlias {
                let hiddenSkillSlugs = await MainActor.run { self.hiddenSkillSlugsForActiveClient() }
                if NativeSkillsVisibilityFilter.shouldHideSkillsResource(originalURI: unwrap.originalURI,
                                                                        hiddenSkillSlugs: hiddenSkillSlugs) {
                    await self.log(level: .info,
                                   category: "skills.visibility",
                                   message: "Rejected hidden skills resource read: \(params.uri)",
                                   metadata: nil)
                    return .init(contents: [])
                }
                return await self.handleSkillsResourceRead(originalURI: unwrap.originalURI, bundledURI: params.uri)
            }
            guard let upstream = await self.fetchOrRehydrateProvider(alias: unwrap.alias) else {
                let message = await MainActor.run { self.messageForUnavailableAlias(unwrap.alias) }
                return .init(contents: [.text(message, uri: params.uri)])
            }
            do {
                let client = try await upstream.ensureClient()
                let contents = try await client.readResource(uri: unwrap.originalURI)
                await MainActor.run { self.clearRestartingAlias(unwrap.alias) }
                await self.log(level: .info, category: "mcp-response", message: "resources/read: (params.uri) -> (unwrap.alias)", metadata: nil)
                return .init(contents: contents)
            } catch {
                await upstream.resetAfterFailure()
                await MainActor.run { self.markRestartingAlias(unwrap.alias) }
                await self.log(level: .error, category: "mcp-error", message: "resources/read failed: (params.uri) - \(error.localizedDescription)", metadata: nil)
                return .init(contents: [.text("Read failed: \(error.localizedDescription)", uri: params.uri)])
            }
        }

        // Prompts list
        await mcpServer.withMethodHandler(ListPrompts.self) { [weak self] _ in
            guard let self else { return .init(prompts: [], nextCursor: nil) }
            await self.log(level: .info, category: "mcp-request", message: "prompts/list", metadata: nil)
            guard let snap = await self.ensureSnapshotReady() else {
                await self.log(level: .error, category: "mcp-error", message: "prompts/list failed: No snapshot available", metadata: nil)
                return .init(prompts: [], nextCursor: nil)
            }
            let hideSkills = await MainActor.run { self.shouldHideSkillsForActiveClient() }
            let prompts: [NamespacedPrompt] = hideSkills
            ? snap.prompts.filter { $0.alias != SkillsCapabilitiesBuilder.alias }
            : snap.prompts
            let wrapped = prompts.map { Prompt(name: $0.namespaced, description: $0.description) }
            return .init(prompts: wrapped, nextCursor: nil)
        }

        // Get prompt
        await mcpServer.withMethodHandler(GetPrompt.self) { [weak self] params in
            guard let self else { return .init(description: nil, messages: []) }
            await self.log(level: .info, category: "mcp-request", message: "prompts/get", metadata: nil)
            let argsDetails = indentLines(describeArguments(params.arguments))
            let detailMessage = "prompt: \(params.name)\nargs:\n\(argsDetails)"
            await self.log(level: .info, category: "mcp-request-detail", message: detailMessage, metadata: nil)
            guard let snap = await self.ensureSnapshotReady() else {
                await self.log(level: .error, category: "mcp-error", message: "prompts/get failed: No snapshot available", metadata: nil)
                return .init(description: nil, messages: [])
            }
            guard let mapping = snap.promptMap[params.name] else { return .init(description: nil, messages: []) }
            let hideSkills = await MainActor.run { self.shouldHideSkillsForActiveClient() }
            if hideSkills, mapping.alias == SkillsCapabilitiesBuilder.alias {
                await self.log(level: .info,
                               category: "skills.visibility",
                               message: "Rejected hidden skills prompt: \(params.name)",
                               metadata: nil)
                return .init(description: nil, messages: [])
            }
            guard let upstream = await self.fetchOrRehydrateProvider(alias: mapping.alias) else {
                let message = await MainActor.run { self.messageForUnavailableAlias(mapping.alias) }
                return .init(description: message, messages: [])
            }
            do {
                let client = try await upstream.ensureClient()
                let (desc, messages) = try await client.getPrompt(name: mapping.original, arguments: params.arguments)
                await MainActor.run { self.clearRestartingAlias(mapping.alias) }
                await self.log(level: .info, category: "mcp-response", message: "prompts/get: \(params.name) -> \(mapping.alias)", metadata: nil)
                return .init(description: desc, messages: messages)
            } catch {
                await upstream.resetAfterFailure()
                await MainActor.run { self.markRestartingAlias(mapping.alias) }
                await self.log(level: .error, category: "mcp-error", message: "prompts/get failed: \(params.name) - \(error.localizedDescription)", metadata: nil)
                return .init(description: "Error: \(error.localizedDescription)", messages: [])
            }
        }

        self.server = mcpServer
    }

    func stop() async {
        let activeServer = server
        warmUpTask?.cancel()
        warmUpTask = nil
        await log(level: .info, category: "server", message: "stop() invoked; activeProviders=\(providers.count)", metadata: nil)
        if let activeServer {
            await activeServer.stop()
        }
        // Proactively disconnect any upstream clients
        for provider in providers.values {
            await provider.disconnect(reason: .manual)
        }
        providers.removeAll()
        self.server = nil
        self.snapshot = nil
        isStarted = false
        skillsLibraryLoaded = false
        clearTempResources()
        lastAnnouncedSnapshotRevision = nil
        lastAnnouncedProjectID = nil
        if let context = persistenceContext {
            saveContextIfNeeded(using: context, force: true)
        }
        persistenceContext = nil
        logProject = nil
        activeClientInfo = nil
    }

    func reload(project: Project,
                snapshot: BundlerAggregator.Snapshot,
                providers: [MCPBundler.Server: any CapabilitiesProvider],
                serverIDs: Set<PersistentIdentifier>? = nil) async throws {
        // Keep the existing server and persistence context, just update the snapshot
        let warmTargets = await updateProviderRegistry(providers, targetedIDs: serverIDs)
        scheduleWarmUp(for: warmTargets)
        updateProviderDescriptors(with: providers)
        self.snapshot = snapshot
        applyProjectRuntimeSettings(from: project)
        updateLogProjectReference(with: project)
        self.pendingSaveCount = 0
        self.lastSaveDate = Date()
        await notifyListChangedIfNeeded(for: project)
    }

    private func notifyListChangedIfNeeded(for project: Project) async {
        guard listChangedNotificationsEnabled else { return }
        let currentRevision = project.snapshotRevision
        let currentProjectID = project.persistentModelID
        let shouldNotify = lastAnnouncedSnapshotRevision != currentRevision
            || lastAnnouncedProjectID != currentProjectID
        guard shouldNotify else { return }
        guard let server = server else { return }

        lastAnnouncedSnapshotRevision = currentRevision
        lastAnnouncedProjectID = currentProjectID

        do {
            try await server.notify(ToolListChangedNotification.message())
            try await server.notify(PromptListChangedNotification.message())
            try await server.notify(ResourceListChangedNotification.message())
        } catch {
            // Intentionally ignore notification failures.
        }
    }

    func setPersistenceContext(_ context: ModelContext?) {
        if let currentContext = persistenceContext {
            saveContextIfNeeded(using: currentContext, force: true)
        }

        logProject = nil
        self.persistenceContext = context
        pendingSaveCount = 0
        lastSaveDate = Date()

        if let context {
            if let project = rehydrateLogProject(in: context) {
                logProject = project
            } else if logProjectID != nil {
                emitLogProjectRehydrationWarningOnce()
            }
            flushPendingLogs(using: context)
        }
    }

    // Start with a transport provided by caller (e.g., CLI helper uses StdioTransport)
    func startServing(transport: any Transport) async throws {
        guard let server = self.server else { throw MCPError.internalError("Bundled server not initialized") }

        // Ensure snapshot is ready before serving
        if await ensureSnapshotReady() == nil {
            await log(level: .error, category: "server", message: "Snapshot not ready when startServing called", metadata: nil)
            // Wait a bit for snapshot to be ready
            for attempt in 1...10 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if await ensureSnapshotReady() != nil {
                    await log(level: .info, category: "server", message: "Snapshot ready after wait \(attempt)", metadata: nil)
                    break
                }
            }
        }

        try await server.start(transport: transport) { [weak self] clientInfo, _ in
            await MainActor.run {
                guard let self else { return }
                self.activeClientInfo = clientInfo
            }
        }
        await server.waitUntilCompleted()
    }

    // MARK: - Provider registry
    private struct ProviderDescriptor {
        let server: MCPBundler.Server
        let provider: any CapabilitiesProvider
    }

    private var providers: [String: any UpstreamProviding] = [:] // alias -> provider
    private var providerDescriptors: [String: ProviderDescriptor] = [:]

    private func updateProviderRegistry(_ map: [MCPBundler.Server: any CapabilitiesProvider],
                                        targetedIDs: Set<PersistentIdentifier>? = nil) async -> [any UpstreamProviding] {
        var warmTargets: [any UpstreamProviding] = []

        var existingByID: [PersistentIdentifier: any UpstreamProviding] = [:]
        var remainingByAlias = providers
        for provider in providers.values {
            if let id = provider.serverIdentifier {
                existingByID[id] = provider
            }
        }

        var nextProviders: [String: any UpstreamProviding] = [:]

        for (server, capabilityProvider) in map {
            let serverID = server.persistentModelID
            let isTargeted: Bool
            if let targets = targetedIDs {
                isTargeted = targets.contains(serverID)
            } else {
                isTargeted = true
            }

            var current: (any UpstreamProviding)?
            if let matched = existingByID.removeValue(forKey: serverID) {
                current = matched
                remainingByAlias.removeValue(forKey: matched.alias)
            } else if let matched = remainingByAlias.removeValue(forKey: server.alias) {
                current = matched
            }

            if let providerInstance = current {
                if isTargeted {
                    let configurationChanged = await providerInstance.update(server: server, provider: capabilityProvider)
                    if configurationChanged {
                        warmTargets.append(providerInstance)
                    }
                } else {
                    providerInstance.synchronize(server: server, provider: capabilityProvider)
                }
                nextProviders[server.alias] = providerInstance
            } else {
                guard isTargeted else { continue }
                let newProvider = makeProvider(for: server, provider: capabilityProvider)
                nextProviders[server.alias] = newProvider
                warmTargets.append(newProvider)
            }
        }

        for (alias, provider) in remainingByAlias {
            let shouldRemove: Bool
            if let targets = targetedIDs {
                if let id = provider.serverIdentifier {
                    shouldRemove = targets.contains(id)
                } else {
                    shouldRemove = true
                }
            } else {
                shouldRemove = true
            }

            if shouldRemove {
                await provider.disconnect(reason: .removed)
            } else {
                nextProviders[alias] = provider
            }
        }

        providers = nextProviders
        return warmTargets
    }

    private func updateProviderDescriptors(with map: [MCPBundler.Server: any CapabilitiesProvider]) {
        providerDescriptors = map.reduce(into: [:]) { partialResult, element in
            let (server, capabilityProvider) = element
            partialResult[server.alias] = ProviderDescriptor(server: server, provider: capabilityProvider)
        }
    }

    private func makeProvider(for server: MCPBundler.Server,
                              provider: any CapabilitiesProvider) -> any UpstreamProviding {
        providerFactory(server, provider) { [weak self] level, category, message in
            guard let self else { return }
            await self.log(level: level, category: category, message: message, metadata: nil)
        }
    }

    private func findProvider(alias: String) -> (any UpstreamProviding)? { providers[alias] }

    func fetchOrRehydrateProvider(alias: String) -> (any UpstreamProviding)? {
        if let existing = providers[alias] {
            restartingAliases.remove(alias)
            return existing
        }
        guard let descriptor = providerDescriptors[alias] else {
            return nil
        }
        let newProvider = makeProvider(for: descriptor.server, provider: descriptor.provider)
        providers[alias] = newProvider
        restartingAliases.remove(alias)
        return newProvider
    }

    @MainActor private func messageForUnavailableAlias(_ alias: String) -> String {
        if restartingAliases.contains(alias) {
            return "Upstream \(alias) is restarting. Try again in a few seconds."
        }
        return "Upstream not available for alias \(alias)"
    }

    @MainActor private func clearRestartingAlias(_ alias: String) {
        restartingAliases.remove(alias)
    }

    @MainActor private func markRestartingAlias(_ alias: String) {
        restartingAliases.insert(alias)
    }

    private func warmUpProviders(_ subset: [any UpstreamProviding]) async {
        guard !subset.isEmpty else { return }
        for provider in subset where provider.shouldKeepConnectionWarm {
            if let status = provider.currentOAuthStatus,
               status == .unauthorized || status == .refreshing {
                await log(level: .info,
                          category: "upstream.warmup",
                          message: "alias=\(provider.alias) warm-up skipped (oauthPending)",
                          metadata: nil)
                continue
            }
            do {
                try await provider.ensureWarmConnection()
                await log(level: .info,
                          category: "upstream.warmup",
                          message: "alias=\(provider.alias) warm-up succeeded",
                          metadata: nil)
            } catch {
                await log(level: .error,
                          category: "upstream.warmup",
                          message: "alias=\(provider.alias) warm-up failed: \(error.localizedDescription)",
                          metadata: nil)
                await provider.resetAfterFailure()
            }
        }
    }

    private func warmUpProviders() async {
        await warmUpProviders(Array(providers.values))
    }

    private func performWarmUp(for providers: [any UpstreamProviding]) async {
        if let handler = customWarmUpHandler {
            await handler(providers)
        } else {
            await warmUpProviders(providers)
        }
    }
    
    private func scheduleWarmUp(for providers: [any UpstreamProviding]) {
        guard !providers.isEmpty else { return }
        warmUpTask?.cancel()
        let subset = providers
        warmUpTask = Task { @MainActor [weak self] in
            defer { self?.warmUpTask = nil }
            guard let self else { return }
            await self.performWarmUp(for: subset)
        }
    }

    private func updateLogProjectReference(with project: Project) {
        logProject = project
        logProjectID = project.persistentModelID
        logProjectToken = project.eventToken
        hasLoggedProjectRehydrationFailure = false
    }

    private func rehydrateLogProject(in context: ModelContext) -> Project? {
        if let project = logProject, project.modelContext === context {
            return project
        }

        if let identifier = logProjectID,
           let resolved = context.model(for: identifier) as? Project {
            hasLoggedProjectRehydrationFailure = false
            return resolved
        }

        if let token = logProjectToken {
            var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.eventToken == token })
            descriptor.fetchLimit = 1
            if let fetched = try? context.fetch(descriptor).first {
                hasLoggedProjectRehydrationFailure = false
                return fetched
            }
        }

        return nil
    }

    private func emitLogProjectRehydrationWarningOnce() {
        guard !hasLoggedProjectRehydrationFailure else { return }
        hasLoggedProjectRehydrationFailure = true
        let stamp = Date().ISO8601Format()
        let message = "[\(stamp)] WARN: BundledServerManager could not rehydrate the log project in the active persistence context; buffering log entries until it becomes available.\n"
        if let data = message.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private static func defaultProviderFactory(server: Server,
                                               provider: any CapabilitiesProvider,
                                               logSink: @escaping LogSink) -> UpstreamProvider {
        UpstreamProvider(server: server, provider: provider, logHandler: logSink)
    }
    // MARK: - Logging

    private enum MCPClientLogMetadata {
        static let nameKey = "mcp_client_name"
        static let versionKey = "mcp_client_version"
        static let unknownName = "unknown"
    }

    private func log(level: LogLevel, category: String, message: String, metadata: Data?) async {
        let logMessage = "[\(Date().ISO8601Format())] \(level.rawValue.uppercased()) [\(category)]: \(message)\n"

        if level == .error {
            if let data = logMessage.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }

        if let context = persistenceContext, logProject?.modelContext !== context {
            logProject = rehydrateLogProject(in: context)
        }

        var project = logProject

        if persistenceContext == nil, let projectContext = project?.modelContext {
            persistenceContext = projectContext
        }

        if let context = persistenceContext, project == nil {
            project = rehydrateLogProject(in: context)
            logProject = project
        }

        if let context = persistenceContext, !pendingLogEntries.isEmpty {
            flushPendingLogs(using: context)
        }

        let enrichedMetadata = metadataWithClientInfo(metadata)
        let entry = LogEntry(project: project,
                             timestamp: Date(),
                             level: level,
                             category: category,
                             message: message,
                             metadata: enrichedMetadata)

        if let context = persistenceContext, project != nil {
            let forceSave = level == .error
            persistLogEntry(entry, using: context, forceSave: forceSave)
        } else {
            pendingLogEntries.append(entry)
        }
    }

    private func metadataWithClientInfo(_ metadata: Data?) -> Data? {
        let name = normalizedMCPClientName()
        let version = normalizedMCPClientVersion()

        var object: [String: Any] = [:]
        if let metadata {
            guard let decoded = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
                return metadata
            }
            object = decoded
        }

        object[MCPClientLogMetadata.nameKey] = name
        if let version {
            object[MCPClientLogMetadata.versionKey] = version
        } else {
            object.removeValue(forKey: MCPClientLogMetadata.versionKey)
        }

        guard JSONSerialization.isValidJSONObject(object) else { return metadata }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func normalizedMCPClientName() -> String {
        guard let activeClientInfo else { return MCPClientLogMetadata.unknownName }
        let trimmed = activeClientInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MCPClientLogMetadata.unknownName : trimmed
    }

    private func normalizedMCPClientVersion() -> String? {
        guard let activeClientInfo else { return nil }
        let trimmed = activeClientInfo.version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let nativeSkillsClientIDs: Set<String> = [
        "claude-code",
        "codex-mcp-client"
    ]

    private func normalizedClientIDForSkillsFiltering() -> String? {
        guard let activeClientInfo else { return nil }
        let trimmed = activeClientInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private func shouldHideSkillsForActiveClient() -> Bool {
        guard hideSkillsForNativeClientsEnabled else { return false }
        guard let clientID = normalizedClientIDForSkillsFiltering() else { return false }
        return Self.nativeSkillsClientIDs.contains(clientID)
    }

    private func hiddenSkillSlugsForActiveClient() -> Set<String> {
        guard shouldHideSkillsForActiveClient() else { return [] }
        guard let clientID = normalizedClientIDForSkillsFiltering() else { return [] }
        guard let context = persistenceContext else { return [] }

        do {
            switch clientID {
            case "claude-code":
                return try hiddenSlugs(forTemplateKey: SkillSyncLocationTemplates.claudeKey, in: context)
            case "codex-mcp-client":
                return try hiddenSlugs(forTemplateKey: SkillSyncLocationTemplates.codexKey, in: context)
            default:
                return []
            }
        } catch {
            return []
        }
    }

    private func hiddenSlugs(forTemplateKey templateKey: String, in context: ModelContext) throws -> Set<String> {
        let locationDescriptor = FetchDescriptor<SkillSyncLocation>(predicate: #Predicate { $0.templateKey == templateKey })
        guard let location = try context.fetch(locationDescriptor).first, location.isManaged else {
            return []
        }

        let enablementDescriptor = FetchDescriptor<SkillLocationEnablement>(predicate: #Predicate { $0.enabled })
        let enablements = try context.fetch(enablementDescriptor)
        let slugs: [String] = enablements.compactMap { enablement -> String? in
            guard enablement.location?.locationId == location.locationId else { return nil }
            return enablement.skill?.slug
        }
        return Set(slugs)
    }

    private func persistLogEntry(_ entry: LogEntry, using context: ModelContext, forceSave: Bool) {
        context.insert(entry)
        enforceRetention(using: context)

        pendingSaveCount += 1

        saveContextIfNeeded(using: context, force: forceSave)
    }

    private func saveContextIfNeeded(using context: ModelContext, force: Bool) {
        guard context.hasChanges else { return }

        let now = Date()
        let timeExceeded = now.timeIntervalSince(lastSaveDate) >= logSaveInterval

        if force || pendingSaveCount >= logSaveBatchSize || timeExceeded {
            do {
                try context.save()
                pendingSaveCount = 0
                lastSaveDate = now
            } catch {
                let errorMessage = "[\(Date().ISO8601Format())] ERROR: Failed to save log entry: \(error)\n"
                if let data = errorMessage.data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            }
        }
    }

    private func enforceRetention(using context: ModelContext) {
        guard let project = logProject else { return }
        let totalCount = project.logs.count
        guard totalCount > logRetentionLimit else { return }

        let overflow = totalCount - logRetentionLimit
        guard overflow > 0 else { return }

        let sorted = project.logs.sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }

        for entry in sorted.prefix(overflow) {
            context.delete(entry)
        }
    }

    private func flushPendingLogs(using context: ModelContext) {
        guard !pendingLogEntries.isEmpty else { return }

        if logProject == nil {
            logProject = rehydrateLogProject(in: context)
        }

        guard let project = logProject else {
            emitLogProjectRehydrationWarningOnce()
            return
        }

        let entries = pendingLogEntries
        pendingLogEntries.removeAll()

        for entry in entries {
            entry.project = project
            persistLogEntry(entry, using: context, forceSave: false)
        }

        saveContextIfNeeded(using: context, force: true)
    }

    nonisolated private func describeArguments(_ arguments: [String: Value]?) -> String {
        let wrapped = arguments.map { Value.object($0) }
        return describeJSON(from: wrapped)
    }

    nonisolated private func describeJSON(from value: Value?) -> String {
        guard let value else { return "null" }
        return jsonString(from: value.toStandardJSON())
    }

    nonisolated private func jsonString(from json: Any) -> String {
        if let dict = json as? [String: Any], JSONSerialization.isValidJSONObject(dict) {
            return jsonString(fromJSONObject: dict)
        }
        if let array = json as? [Any], JSONSerialization.isValidJSONObject(array) {
            return jsonString(fromJSONObject: array)
        }
        if let string = json as? String {
            return "\"\(string)\""
        }
        if let number = json as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if json is NSNull {
            return "null"
        }
        return "\(json)"
    }

    nonisolated private func jsonString(fromJSONObject object: Any) -> String {
        let preferredOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: preferredOptions),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: []),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(object)"
    }

    nonisolated private func indentLines(_ text: String, indent: String = "  ") -> String {
        let components = text.components(separatedBy: "\n")
        return components.map { indent + $0 }.joined(separator: "\n")
    }

    nonisolated private func contextOptimizationTools(availableTools: [NamespacedTool],
                                                      includeSkillsInDescription: Bool) -> [Tool] {
        let summary = summarizeTools(for: availableTools)
        let baseDescription = includeSkillsInDescription
        ? ContextOptimizationTools.searchDescription
        : "Search the bundled servers to discover available tools."
        let searchDescription = summary.isEmpty ? baseDescription : baseDescription + summary
        let callDescription = ContextOptimizationTools.callDescription

        return [
            Tool(name: ContextOptimizationTools.searchName,
                 description: searchDescription,
                 inputSchema: ContextOptimizationTools.searchSchema,
                 annotations: Tool.Annotations(title: ContextOptimizationTools.searchTitle)),
            Tool(name: ContextOptimizationTools.callName,
                 description: callDescription,
                 inputSchema: ContextOptimizationTools.callSchema,
                 annotations: Tool.Annotations(title: ContextOptimizationTools.callTitle))
        ]
    }

    nonisolated private func fetchTempFileToolDescriptor() -> Tool {
        Tool(name: Self.fetchTempFileToolName,
             description: Self.fetchTempFileToolDescription,
             inputSchema: Self.fetchTempFileInputSchema,
             annotations: Tool.Annotations(title: Self.fetchTempFileToolTitle))
    }

    private func handleSearchTool(arguments: [String: Value]?,
                                  snapshot: BundlerAggregator.Snapshot) async -> CallTool.Result {
        var query: String?
        if let provided = arguments?["query"] {
            guard case let .string(rawQuery) = provided else {
                let message = "search_tool failed: query must be a string"
                await log(level: .error, category: "mcp-error", message: message, metadata: nil)
                return .init(content: [.text("Invalid arguments: query must be a string")], isError: true)
            }
            let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            query = trimmed.isEmpty ? nil : trimmed
        }

        let hiddenSkillSlugs = hiddenSkillSlugsForActiveClient()
        let allTools = NativeSkillsVisibilityFilter.filterTools(snapshot.tools, hiddenSkillSlugs: hiddenSkillSlugs)
        let normalized = query?.lowercased()
        let tokens: [String]?
        if let normalized {
            tokens = normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        } else {
            tokens = nil
        }

        let matches: [NamespacedTool]
        if let tokens, !tokens.isEmpty {
            matches = allTools.filter { toolMatches($0, queryTokens: tokens) }
        } else {
            matches = allTools
        }

        var matchEntries = matches.map { makeSearchResultEntry(for: $0) }
        if fetchTempFileMatches(queryTokens: tokens) {
            matchEntries.append(fetchTempFileSearchEntry())
        }

        let payload: [String: Any] = [
            "query": query ?? NSNull(),
            "total": allTools.count + 1,
            "matches": matchEntries
        ]
        let json = jsonString(fromJSONObject: payload)
        let detail = "search_tool query: \(query ?? "<all>") matches: \(matchEntries.count)"
        await log(level: .info, category: "mcp-response", message: detail, metadata: nil)
        return .init(content: [.text(json)], isError: false)
    }

    private func makeSearchResultURI(query: String?) -> String {
        guard let query, !query.isEmpty else {
            return "mcp-bundler://context-optimizations/search?query="
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "mcp-bundler://context-optimizations/search?query=\(encoded)"
    }

    nonisolated private func summarizeTools(for tools: [NamespacedTool]) -> String {
        guard !tools.isEmpty else { return "" }

        let grouped = Dictionary(grouping: tools, by: \.alias)
        let segments = grouped.sorted { $0.key < $1.key }.map { alias, tools -> String in
            let friendlyNames = tools
                .sorted { $0.namespaced < $1.namespaced }
                .map(friendlyToolName)
                .uniqued()
            let joined = friendlyNames.joined(separator: ", ")
            return "\(alias): \(joined)"
        }

        guard !segments.isEmpty else { return "" }
        let joinedSegments = segments.joined(separator: "; ")
        return " Available examples — \(joinedSegments)."
    }

    nonisolated private func friendlyToolName(_ tool: NamespacedTool) -> String {
        if let title = tool.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return beautify(tool.original)
    }

    nonisolated private func beautify(_ raw: String) -> String {
        let replaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard !replaced.isEmpty else { return raw }

        var characters: [Character] = []
        for (index, char) in replaced.enumerated() {
            if index > 0,
               char.isUppercase,
               let previous = replaced[replaced.index(replaced.startIndex, offsetBy: index - 1)].unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(previous) {
                characters.append(" ")
            }
            characters.append(char)
        }

        let spaced = String(characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.split(separator: " ").map { word in
            var lower = word.lowercased()
            if let first = lower.first {
                lower.replaceSubrange(lower.startIndex...lower.startIndex, with: String(first).uppercased())
            }
            return lower
        }.joined(separator: " ")
    }

    private func applyProjectRuntimeSettings(from project: Project) {
        contextOptimizationsEnabled = project.contextOptimizationsEnabled
        hideSkillsForNativeClientsEnabled = project.hideSkillsForNativeClients
        storeLargeResponsesAsFiles = project.storeLargeToolResponsesAsFiles
        largeResponseThreshold = max(0, project.largeToolResponseThreshold)
        projectSlugForLargeResponses = Self.sanitizedFileComponent(project.name, fallback: "project")
    }

    private func processLargeToolResponse(for namespacedTool: String,
                                          result: CallTool.Result) async -> CallTool.Result {
        guard storeLargeResponsesAsFiles else { return result }
        let textSegments = result.content.compactMap { segment -> String? in
            if case let .text(value) = segment {
                return value
            }
            return nil
        }
        guard !textSegments.isEmpty else { return result }
        let aggregated = textSegments.joined(separator: "\n\n")
        guard aggregated.count > largeResponseThreshold else { return result }

        do {
            let fileDescriptor = try writeLargeToolResponseToFile(text: aggregated, namespacedTool: namespacedTool)
            var retainedContent = result.content.filter { segment in
                if case .text = segment { return false }
                return true
            }
            let sizeDescription = Self.byteFormatter.string(fromByteCount: Int64(fileDescriptor.byteCount))
            let useMetaTools = await MainActor.run { self.contextOptimizationsEnabled }
            let pointerMessage = Self.largeResponsePointerMessage(path: fileDescriptor.path,
                                                                  sizeDescription: sizeDescription,
                                                                  useMetaTools: useMetaTools)
            retainedContent.append(.text(pointerMessage))
            await log(level: .info,
                      category: "mcp-response",
                      message: "Stored large response (\(aggregated.count) chars) for \(namespacedTool) at \(fileDescriptor.path) [\(sizeDescription)]",
                      metadata: nil)
            return CallTool.Result(content: retainedContent, isError: result.isError)
        } catch {
            await log(level: .error,
                      category: "mcp-error",
                      message: "Failed to store large response for \(namespacedTool): \(error.localizedDescription)",
                      metadata: nil)
            return result
        }
    }

    private static func largeResponsePointerMessage(path: String,
                                                    sizeDescription: String,
                                                    useMetaTools: Bool) -> String {
        let invocationExamples: String
        if useMetaTools {
            invocationExamples = """
            If your client can't reach /tmp or /var/folders, call fetch_temp_file with:
            call_tool("fetch_temp_file", { "path": "\(path)" })
            To read just a portion, specify offsets:
            call_tool("fetch_temp_file", { "path": "\(path)", "offset": 0, "length": 2000 })
            """
        } else {
            invocationExamples = """
            If your client can't reach /tmp or /var/folders, call fetch_temp_file with:
            fetch_temp_file({ "path": "\(path)" })
            To read just a portion, specify offsets:
            fetch_temp_file({ "path": "\(path)", "offset": 0, "length": 2000 })
            """
        }

        return """
        Saved response to \(path)
        Size: \(sizeDescription). File is large; read it in chunks (e.g., `sed -n '1,200p' "\(path)"`).
        \(invocationExamples)
        """
    }

    private func handleFetchTempFile(arguments: [String: Value]?) async -> CallTool.Result {
        guard let rawPathValue = arguments?["path"] else {
            return await fetchTempFileFailure(userFacing: "Invalid arguments: path is required",
                                              logMessage: "fetch_temp_file failed: missing path argument")
        }
        guard case let .string(rawPath) = rawPathValue else {
            return await fetchTempFileFailure(userFacing: "Invalid arguments: path must be a string",
                                              logMessage: "fetch_temp_file failed: non-string path argument")
        }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return await fetchTempFileFailure(userFacing: "Invalid arguments: path cannot be empty",
                                              logMessage: "fetch_temp_file failed: empty path argument")
        }
        guard Self.pathIsWithinAllowedTempRoots(trimmed) else {
            return await fetchTempFileFailure(userFacing: "Path must begin with /tmp or /var/folders",
                                              logMessage: "fetch_temp_file failed: path \(trimmed) outside allowed temp directories")
        }

        let offset: Int
        if let offsetValue = arguments?["offset"] {
            guard case let .int(rawOffset) = offsetValue, rawOffset >= 0 else {
                let description = String(describing: offsetValue)
                return await fetchTempFileFailure(userFacing: "Invalid arguments: offset must be a non-negative integer",
                                                  logMessage: "fetch_temp_file failed: invalid offset argument \(description)")
            }
            offset = rawOffset
        } else {
            offset = 0
        }

        let length: Int?
        if let lengthValue = arguments?["length"] {
            guard case let .int(rawLength) = lengthValue, rawLength > 0 else {
                let description = String(describing: lengthValue)
                return await fetchTempFileFailure(userFacing: "Invalid arguments: length must be a positive integer",
                                                  logMessage: "fetch_temp_file failed: invalid length argument \(description)")
            }
            length = rawLength
        } else {
            length = nil
        }

        let resolvedURL = URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path
        guard Self.pathIsWithinAllowedTempRoots(resolvedPath) else {
            return await fetchTempFileFailure(userFacing: "Path must stay within /tmp or /var/folders",
                                              logMessage: "fetch_temp_file failed: resolved path \(resolvedPath) escaped allowed temp directories")
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return await fetchTempFileFailure(userFacing: "File not found: \(trimmed)",
                                              logMessage: "fetch_temp_file failed: missing file \(resolvedPath)")
        }
        if isDirectory.boolValue {
            return await fetchTempFileFailure(userFacing: "Path refers to a directory, not a file",
                                              logMessage: "fetch_temp_file failed: directory \(resolvedPath)")
        }

        do {
            let attributes = try fm.attributesOfItem(atPath: resolvedPath)
            if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
                return await fetchTempFileFailure(userFacing: "Path must reference a regular file",
                                                  logMessage: "fetch_temp_file failed: non-regular file \(resolvedPath)")
            }

            let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if byteCount > Self.fetchTempFileMaxBytes {
                let limitDescription = Self.byteFormatter.string(fromByteCount: Int64(Self.fetchTempFileMaxBytes))
                return await fetchTempFileFailure(userFacing: "File larger than supported limit (\(limitDescription)). Please stream via shell instead.",
                                                  logMessage: "fetch_temp_file failed: \(resolvedPath) exceeds limit (\(byteCount) bytes)")
            }

            let data = try Data(contentsOf: resolvedURL)
            guard let text = String(data: data, encoding: .utf8) else {
                return await fetchTempFileFailure(userFacing: "Unable to decode file as UTF-8 text.",
                                                  logMessage: "fetch_temp_file failed: UTF-8 decode error for \(resolvedPath)")
            }

            let totalCharacters = text.count
            if offset > totalCharacters {
                return await fetchTempFileFailure(userFacing: "Offset exceeds file length.",
                                                  logMessage: "fetch_temp_file failed: offset \(offset) beyond length \(totalCharacters) for \(resolvedPath)")
            }

            let slicedText: String
            if offset == 0 && length == nil {
                slicedText = text
            } else {
                let startIndex = text.index(text.startIndex, offsetBy: offset)
                if let length {
                    let available = totalCharacters - offset
                    let chunkLength = min(length, available)
                    let endIndex = text.index(startIndex, offsetBy: chunkLength)
                    slicedText = String(text[startIndex..<endIndex])
                } else {
                    slicedText = String(text[startIndex...])
                }
            }

            let sizeDescription = Self.byteFormatter.string(fromByteCount: Int64(byteCount))
            var logComponents: [String] = ["Fetched \(resolvedPath) (\(sizeDescription))"]
            if offset != 0 || length != nil {
                let lengthDescription = length.map(String.init) ?? "nil"
                logComponents.append("offset=\(offset)")
                logComponents.append("length=\(lengthDescription)")
            }
            await log(level: .info,
                      category: "temp-file.fetch",
                      message: logComponents.joined(separator: " "),
                      metadata: nil)
            return .init(content: [.text(slicedText)], isError: false)
        } catch {
            return await fetchTempFileFailure(userFacing: "Unable to read file: \(error.localizedDescription)",
                                              logMessage: "fetch_temp_file failed: \(resolvedPath) read error: \(error.localizedDescription)")
        }
    }

    private func fetchTempFileFailure(userFacing: String, logMessage: String) async -> CallTool.Result {
        await log(level: .error, category: "mcp-error", message: logMessage, metadata: nil)
        return .init(content: [.text(userFacing)], isError: true)
    }

    private static func pathIsWithinAllowedTempRoots(_ path: String) -> Bool {
        fetchTempFileAllowedPrefixes.contains { prefix in
            path == prefix || path.hasPrefix("\(prefix)/")
        }
    }

    private func writeLargeToolResponseToFile(text: String,
                                              namespacedTool: String) throws -> TempFileDescriptor {
        let timestamp = Self.largeResponseFilenameFormatter.string(from: Date())
        let projectComponent = projectSlugForLargeResponses
        let toolComponent = Self.sanitizedFileComponent(namespacedTool, fallback: "tool")
        let ext = Self.looksLikeJSON(text) ? "json" : "txt"
        let mimeType = ext == "json" ? "application/json" : "text/plain; charset=utf-8"
        let fm = FileManager.default
        let directory = temporaryDirectoryProvider()
        let baseName = "\(timestamp)_\(projectComponent)__\(toolComponent)"

        var candidate = baseName
        var counter = 1
        var fileName = "\(candidate).\(ext)"
        var url = directory.appendingPathComponent(fileName)

        while fm.fileExists(atPath: url.path) {
            candidate = "\(baseName)-\(counter)"
            counter += 1
            fileName = "\(candidate).\(ext)"
            url = directory.appendingPathComponent(fileName)
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return TempFileDescriptor(path: url.path, mimeType: mimeType, fileName: fileName, byteCount: byteCount)
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
        (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    private static let largeResponseFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private static func sanitizedFileComponent(_ value: String, fallback: String, maxLength: Int = 48) -> String {
        guard !value.isEmpty else { return fallback }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        var buffer: [Character] = []
        var previousUnderscore = false

        for scalar in value.lowercased().unicodeScalars {
            let character: Character
            if allowed.contains(scalar) {
                character = Character(scalar)
            } else {
                character = "_"
            }

            let isUnderscore = character == "_"
            if isUnderscore && previousUnderscore {
                continue
            }

            previousUnderscore = isUnderscore
            buffer.append(character)
        }

        var result = String(buffer).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { result = fallback }
        if result.count > maxLength {
            let index = result.index(result.startIndex, offsetBy: maxLength)
            result = String(result[..<index])
        }
        return result
    }

    private func registerTempResource(for file: TempFileDescriptor) -> String {
        let identifier = UUID().uuidString
        let uri = "mcp-bundler-temp://resource/\(identifier)"
        tempResources[uri] = TempResource(path: file.path,
                                          mimeType: file.mimeType,
                                          displayName: file.fileName,
                                          createdAt: Date())
        tempResourceOrder.append(uri)
        pruneTempResourcesIfNeeded()
        return uri
    }

    private func pruneTempResourcesIfNeeded() {
        guard tempResourceOrder.count > tempResourceLimit else { return }
        let overflow = tempResourceOrder.count - tempResourceLimit
        for _ in 0..<overflow {
            guard let oldest = tempResourceOrder.first else { break }
            tempResourceOrder.removeFirst()
            tempResources.removeValue(forKey: oldest)
        }
    }

    private func clearTempResources() {
        tempResources.removeAll()
        tempResourceOrder.removeAll()
    }

    private func serveTempResource(uri: String, resource: TempResource) async -> ReadResource.Result {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resource.path))
            if resource.mimeType.contains("json") || resource.mimeType.contains("text") {
                if let text = String(data: data, encoding: .utf8) {
                    await log(level: .info, category: "temp-resource", message: "Served temp text resource \(resource.displayName)", metadata: nil)
                    return .init(contents: [.text(text, uri: uri, mimeType: resource.mimeType)])
                }
            }
            await log(level: .info, category: "temp-resource", message: "Served temp binary resource \(resource.displayName)", metadata: nil)
            return .init(contents: [.binary(data, uri: uri, mimeType: resource.mimeType)])
        } catch {
            tempResources.removeValue(forKey: uri)
            tempResourceOrder.removeAll { $0 == uri }
            await log(level: .error, category: "temp-resource", message: "Failed to read temp resource \(resource.displayName): \(error.localizedDescription)", metadata: nil)
            return .init(contents: [.text("Temp resource unavailable: \(error.localizedDescription)", uri: uri)])
        }
    }

    private func handleMetaToolCall(arguments: [String: Value]?,
                                    snapshot: BundlerAggregator.Snapshot) async -> CallTool.Result {
        guard let arguments else {
            await log(level: .error, category: "mcp-error", message: "call_tool failed: missing arguments", metadata: nil)
            return .init(content: [.text("Invalid arguments: tool_name is required")], isError: true)
        }
        guard case let .string(rawToolName)? = arguments["tool_name"] else {
            await log(level: .error, category: "mcp-error", message: "call_tool failed: tool_name must be a string", metadata: nil)
            return .init(content: [.text("Invalid arguments: tool_name must be a string")], isError: true)
        }
        let trimmedTool = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTool.isEmpty else {
            await log(level: .error, category: "mcp-error", message: "call_tool failed: tool_name cannot be empty", metadata: nil)
            return .init(content: [.text("Invalid arguments: tool_name cannot be empty")], isError: true)
        }

        var forwardedArguments: [String: Value]? = nil
        if let provided = arguments["arguments"] {
            switch provided {
            case .object(let object):
                forwardedArguments = object
            case .null:
                forwardedArguments = nil
            default:
                await log(level: .error, category: "mcp-error", message: "call_tool failed: arguments must be an object", metadata: nil)
                return .init(content: [.text("Invalid arguments: arguments must be an object")], isError: true)
            }
        }

        await log(level: .info,
                  category: "mcp-request-detail",
                  message: "call_tool target: \(trimmedTool)",
                  metadata: nil)
        return await routeToolCall(named: trimmedTool,
                                   arguments: forwardedArguments,
                                   snapshot: snapshot)
    }

    private func routeToolCall(named name: String,
                               arguments: [String: Value]?,
                               snapshot: BundlerAggregator.Snapshot) async -> CallTool.Result {
        if name == Self.fetchTempFileToolName {
            return await handleFetchTempFile(arguments: arguments)
        }

        guard let mapping = snapshot.toolMap[name] else {
            await log(level: .error, category: "mcp-error", message: "tools/call failed: Unknown tool: \(name)", metadata: nil)
            return .init(content: [.text("Unknown tool: \(name)")], isError: true)
        }

        if mapping.alias == skillsAlias {
            let hiddenSkillSlugs = hiddenSkillSlugsForActiveClient()
            if NativeSkillsVisibilityFilter.shouldHideSkillsTool(originalToolName: mapping.original,
                                                                hiddenSkillSlugs: hiddenSkillSlugs) {
                await log(level: .info,
                          category: "skills.visibility",
                          message: "Rejected hidden skills tool call: \(name)",
                          metadata: nil)
                await log(level: .error, category: "mcp-error", message: "tools/call failed: Unknown tool: \(name)", metadata: nil)
                return .init(content: [.text("Unknown tool: \(name)")], isError: true)
            }
            let result = await handleSkillsToolCall(namespaced: name,
                                                    original: mapping.original,
                                                    arguments: arguments)
            return await processLargeToolResponse(for: name, result: result)
        }

        guard let upstream = await fetchOrRehydrateProvider(alias: mapping.alias) else {
            let message = await MainActor.run { self.messageForUnavailableAlias(mapping.alias) }
            await log(level: .error, category: "mcp-error", message: "tools/call failed: \(message)", metadata: nil)
            return .init(content: [.text(message)], isError: true)
        }

        do {
            let client = try await upstream.ensureClient()
            let ready = await waitUntilUpstreamReady(upstream, timeout: 8.0)
            if !ready {
                await log(level: .error,
                          category: "mcp-error",
                          message: "tools/call failed: \(name) - Upstream not ready",
                          metadata: nil)
                return .init(content: [.text("Upstream not ready for \(mapping.alias)")], isError: true)
            }

            let (content, isError) = try await callToolWithSingleRetry(
                upstream: (upstream as? UpstreamProvider),
                client: client,
                name: mapping.original,
                arguments: arguments
            )
            await MainActor.run { self.clearRestartingAlias(mapping.alias) }
            await log(level: .info,
                      category: "mcp-response",
                      message: "tools/call: \(name) -> \(mapping.alias), success: \(!(isError ?? false))",
                      metadata: nil)
            let result = CallTool.Result(content: content, isError: isError)
            return await processLargeToolResponse(for: name, result: result)
        } catch {
            await upstream.resetAfterFailure()
            await MainActor.run { self.markRestartingAlias(mapping.alias) }
            await log(level: .error,
                      category: "mcp-error",
                      message: "tools/call failed: \(name) - \(error.localizedDescription)",
                      metadata: nil)
            return .init(content: [.text("Upstream error: \(error.localizedDescription)")], isError: true)
        }
    }

    private func toolMatches(_ tool: NamespacedTool, queryTokens: [String]) -> Bool {
        guard !queryTokens.isEmpty else { return true }

        let searchableFields = [
            tool.namespaced,
            tool.alias,
            tool.original,
            tool.title ?? "",
            tool.description ?? "",
            friendlyToolName(tool)
        ]

        let normalizedFields = searchableFields.map(normalizeSearchField)

        return queryTokens.allSatisfy { token in
            normalizedFields.contains { $0.contains(token) }
        }
    }

    private func normalizeSearchField(_ value: String) -> String {
        let lowered = value.lowercased()
        let separators = CharacterSet(charactersIn: "-_/")
        let replaced = lowered.unicodeScalars.map { separators.contains($0) ? " " : Character($0) }
        let string = String(replaced)
        let condensed = string
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return condensed
    }

    private func makeSearchResultEntry(for tool: NamespacedTool) -> [String: Any] {
        var entry: [String: Any] = [
            "name": tool.namespaced,
            "alias": tool.alias,
            "original": tool.original,
            "source": tool.alias == skillsAlias ? "skills" : "server"
        ]
        entry["title"] = tool.title ?? NSNull()
        entry["description"] = tool.description ?? NSNull()
        if let schema = tool.inputSchema?.toStandardJSON() {
            entry["input_schema"] = schema
        } else {
            entry["input_schema"] = NSNull()
        }
        return entry
    }

    private func fetchTempFileSearchEntry() -> [String: Any] {
        var entry: [String: Any] = [
            "name": Self.fetchTempFileToolName,
            "alias": Self.fetchTempFileSearchAlias,
            "original": Self.fetchTempFileToolName,
            "source": "bundler",
            "title": Self.fetchTempFileToolTitle,
            "description": Self.fetchTempFileSearchDescription
        ]
        entry["input_schema"] = Self.fetchTempFileInputSchema.toStandardJSON()
        return entry
    }

    private func fetchTempFileMatches(queryTokens: [String]?) -> Bool {
        guard let queryTokens, !queryTokens.isEmpty else { return true }
        let haystack = """
        \(Self.fetchTempFileToolName) \(Self.fetchTempFileToolTitle.lowercased()) fetch temp file tmp temporary var folders var/folders bundler chunk offset length slice
        """
        return queryTokens.allSatisfy { token in
            haystack.contains(token)
        }
    }

    private func refreshSkillsLibrary(reason: String) async {
        do {
            try await skillsLibrary.reload()
            skillsLibraryLoaded = true
            await log(level: .info, category: "skills.registry", message: "Skills library reloaded (\(reason))", metadata: nil)
        } catch {
            skillsLibraryLoaded = false
            await log(level: .error,
                      category: "skills.registry",
                      message: "Skills library reload failed (\(reason)): \(error.localizedDescription)",
                      metadata: nil)
        }
    }

    private func ensureSkillsLibraryReady(reason: String) async -> Bool {
        if skillsLibraryLoaded {
            return true
        }
        await refreshSkillsLibrary(reason: reason)
        return skillsLibraryLoaded
    }

    private func handleSkillsToolCall(namespaced: String,
                                      original: String,
                                      arguments: [String: Value]?) async -> CallTool.Result {
        if original == SkillsCapabilitiesBuilder.compatibilityToolName {
            return await handleSkillsFetchResource(arguments: arguments)
        } else {
            return await handleSkillInvocation(slug: original, arguments: arguments)
        }
    }

    func handleSkillInvocation(slug: String,
                               arguments: [String: Value]?) async -> CallTool.Result {
        guard await ensureSkillsLibraryReady(reason: "tool:\(slug)") else {
            return .init(content: [.text("Skills library unavailable")], isError: true)
        }
        guard let arguments,
              case let .string(taskValue)? = arguments["task"] else {
            await log(level: .error, category: "skills.call", message: "Missing task argument for skill \(slug)", metadata: nil)
            return .init(content: [.text("Invalid arguments: missing task")], isError: true)
        }
        let task = taskValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            await log(level: .error, category: "skills.call", message: "Empty task argument for skill \(slug)", metadata: nil)
            return .init(content: [.text("Invalid arguments: task must be non-empty")], isError: true)
        }

        let skills = await skillsLibrary.list()
        guard let info = skills.first(where: { $0.slug == slug }) else {
            await log(level: .error, category: "skills.call", message: "Skill \(slug) not found in library", metadata: nil)
            return .init(content: [.text("Skill not available: \(slug)")], isError: true)
        }

        let record = fetchSkillRecord(slug: slug)
        let displayName = normalized(record?.displayNameOverride) ?? info.name
        let description = normalized(record?.descriptionOverride) ?? info.description

        do {
            let instructions = try await skillsLibrary.readInstructions(slug: slug)
            let decoratedInstructions = instructionsWithSkillPreamble(instructions, displayName: displayName)
            let metadata: [String: Any] = [
                "name": displayName,
                "description": description,
                "license": info.license ?? NSNull(),
                "allowed_tools": info.allowedTools,
                "extra": info.extra
            ]

            let resourcesPayload: [[String: Any]] = info.resources.map { resource in
                let originalURI = skillResourceOriginalURI(slug: slug, relativePath: resource.relativePath)
                return [
                    "uri": BundlerURI.wrap(alias: skillsAlias, originalURI: originalURI),
                    "name": "\(slug)/\(resource.relativePath)",
                    "mime_type": resource.mimeType ?? NSNull()
                ]
            }

            let payload: [String: Any] = [
                "skill": slug,
                "task": task,
                "metadata": metadata,
                "resources": resourcesPayload,
                "instructions": decoratedInstructions,
                "usage": SkillsInstructionCopy.skillsUsageText
            ]

            guard let json = encodeJSONObject(payload) else {
                await log(level: .error, category: "skills.call", message: "Failed to encode JSON payload for skill \(slug)", metadata: nil)
                return .init(content: [.text("Internal error encoding skill payload")], isError: true)
            }

            let logMetadata = info.allowedTools.isEmpty ? nil : encodeJSONData(["allowed_tools": info.allowedTools])
            await log(level: .info, category: "skills.call", message: "Handled skill tool \(slug)", metadata: logMetadata)
            return .init(content: [.text(json)], isError: false)
        } catch {
            await log(level: .error, category: "skills.call", message: "Failed to read instructions for \(slug): \(error.localizedDescription)", metadata: nil)
            return .init(content: [.text("Unable to read skill instructions: \(error.localizedDescription)")], isError: true)
        }
    }

    private func handleSkillsFetchResource(arguments: [String: Value]?) async -> CallTool.Result {
        guard await ensureSkillsLibraryReady(reason: SkillsCapabilitiesBuilder.compatibilityToolName) else {
            return .init(content: [.text("Skills library unavailable")], isError: true)
        }
        guard let arguments,
              case let .string(uriValue)? = arguments["resource_uri"] else {
            await log(level: .error, category: "skills.fetch", message: "Missing resource_uri argument", metadata: nil)
            return .init(content: [.text("Invalid arguments: resource_uri is required")], isError: true)
        }
        let resourceURI = uriValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resourceURI.isEmpty else {
            await log(level: .error, category: "skills.fetch", message: "resource_uri argument empty", metadata: nil)
            return .init(content: [.text("Invalid arguments: resource_uri must be non-empty")], isError: true)
        }
        guard let unwrap = BundlerURI.unwrap(resourceURI), unwrap.alias == skillsAlias,
              let parsed = parseSkillOriginalURI(unwrap.originalURI) else {
            await log(level: .error, category: "skills.fetch", message: "resource_uri \(resourceURI) did not decode to skills alias", metadata: nil)
            return .init(content: [.text("Invalid resource URI")], isError: true)
        }

        let hiddenSkillSlugs = hiddenSkillSlugsForActiveClient()
        if hiddenSkillSlugs.contains(parsed.slug) {
            await log(level: .info,
                      category: "skills.visibility",
                      message: "Rejected hidden skills fetch_resource: \(resourceURI)",
                      metadata: nil)
            return .init(content: [.text("Resource unavailable via MCP because this skill is enabled natively for this client.")],
                         isError: true)
        }

        do {
            let result = try await skillsLibrary.readResource(slug: parsed.slug, relPath: parsed.path)
            let content: String
            let encoding: String
            if result.isTextUTF8, let text = String(data: result.data, encoding: .utf8) {
                content = text
                encoding = "utf-8"
            } else {
                content = result.data.base64EncodedString()
                encoding = "base64"
            }

            let payload: [String: Any] = [
                "uri": resourceURI,
                "name": "\(parsed.slug)/\(parsed.path)",
                "mime_type": result.mimeType ?? NSNull(),
                "content": content,
                "encoding": encoding
            ]

            guard let json = encodeJSONObject(payload) else {
                await log(level: .error, category: "skills.fetch", message: "Failed to encode fetch_resource payload for \(resourceURI)", metadata: nil)
                return .init(content: [.text("Internal error encoding resource payload")], isError: true)
            }

            await log(level: .info, category: "skills.fetch", message: "Fetched resource \(parsed.slug)/\(parsed.path)", metadata: nil)
            return .init(content: [.text(json)], isError: false)
        } catch {
            await log(level: .error, category: "skills.fetch", message: "Failed to read resource \(parsed.slug)/\(parsed.path): \(error.localizedDescription)", metadata: nil)
            return .init(content: [.text("Unable to read resource: \(error.localizedDescription)")], isError: true)
        }
    }

    private func handleSkillsResourceRead(originalURI: String, bundledURI: String) async -> ReadResource.Result {
        guard await ensureSkillsLibraryReady(reason: "resources/read") else {
            return .init(contents: [.text("Skills library unavailable", uri: bundledURI)])
        }
        guard let parsed = parseSkillOriginalURI(originalURI) else {
            await log(level: .error, category: "skills.resource", message: "Invalid skills resource URI: \(originalURI)", metadata: nil)
            return .init(contents: [.text("Invalid skills resource URI", uri: bundledURI)])
        }

        do {
            let result = try await skillsLibrary.readResource(slug: parsed.slug, relPath: parsed.path)
            if result.isTextUTF8, let text = String(data: result.data, encoding: .utf8) {
                await log(level: .info, category: "skills.resource", message: "Served text resource \(parsed.slug)/\(parsed.path)", metadata: nil)
                return .init(contents: [.text(text, uri: bundledURI, mimeType: result.mimeType)])
            } else {
                await log(level: .info, category: "skills.resource", message: "Served binary resource \(parsed.slug)/\(parsed.path)", metadata: nil)
                return .init(contents: [.binary(result.data, uri: bundledURI, mimeType: result.mimeType)])
            }
        } catch {
            await log(level: .error, category: "skills.resource", message: "Failed to read resource \(parsed.slug)/\(parsed.path): \(error.localizedDescription)", metadata: nil)
            return .init(contents: [.text("Resource read failed: \(error.localizedDescription)", uri: bundledURI)])
        }
    }

    private func fetchSkillRecord(slug: String) -> SkillRecord? {
        guard let context = persistenceContext else { return nil }
        let descriptor = FetchDescriptor<SkillRecord>(predicate: #Predicate { $0.slug == slug })
        return try? context.fetch(descriptor).first
    }

    private func parseSkillOriginalURI(_ uri: String) -> (slug: String, path: String)? {
        guard let url = URL(string: uri), url.scheme == "mcpbundler-skill", let slugHost = url.host else {
            return nil
        }
        let decodedSlug = slugHost.removingPercentEncoding ?? slugHost
        let rawPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rawPath.isEmpty else {
            return nil
        }
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        guard !decodedPath.contains("..") else {
            return nil
        }
        return (decodedSlug, decodedPath)
    }

    private func skillResourceOriginalURI(slug: String, relativePath: String) -> String {
        let encodedSlug = encodeSkillSlug(slug)
        let encodedPath = relativePath
            .split(separator: "/")
            .map { encodeSkillPathComponent(String($0)) }
            .joined(separator: "/")
        return "mcpbundler-skill://\(encodedSlug)/\(encodedPath)"
    }

    private func encodeSkillSlug(_ value: String) -> String {
        var allowed = CharacterSet.urlHostAllowed
        allowed.remove(charactersIn: "%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func encodeSkillPathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func instructionsWithSkillPreamble(_ instructions: String, displayName: String) -> String {
        let trimmedPrefix = instructions.drop { $0.isWhitespace || $0.isNewline }
        if String(trimmedPrefix).hasPrefix("[Skill Notice]") {
            return instructions
        }
        let preamble = SkillsInstructionCopy.skillInstructionPreamble(displayName: displayName)
        guard !instructions.isEmpty else { return preamble }
        return "\(preamble)\n\n\(instructions)"
    }

    private func encodeJSONObject(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeJSONData(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func ensureSnapshotReady() async -> BundlerAggregator.Snapshot? {
        if let snapshot {
            return snapshot
        }

        guard let project = logProject,
              let restored = try? ProjectSnapshotCache.snapshot(for: project) else {
            return nil
        }

        self.snapshot = restored
        return restored
    }

    // Wait until an upstream provider reports ready.
    @MainActor
    private func waitUntilUpstreamReady(_ upstream: UpstreamProviding,
                                        timeout: TimeInterval = 8.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let up = upstream as? UpstreamProvider, up.state == .ready {
                return true
            }
            do {
                _ = try await upstream.ensureClient()
            } catch {
                // swallow and retry until timeout
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { }
        }
        return false
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for element in self {
            if seen.insert(element).inserted {
                result.append(element)
            }
        }
        return result
    }
}

// MARK: - Upstream provider wrapper (lazy client)

@MainActor
final class UpstreamProvider: @unchecked Sendable, UpstreamProviding {
    enum State: String {
        case idle
        case initializing
        case ready
        case shuttingDown
        case terminated
    }

    private var server: MCPBundler.Server
    private var provider: any CapabilitiesProvider
    private var client: MCP.Client?
    private var streamingTransport: HTTPClientTransport?
    private var httpTransport: HTTPClientTransport?
    private var stdioTransport: StdioTransport?
    private var stdioProcess: Process?
    private var stdioStderrTask: Task<Void, Never>?
    private var stdioStderrHandle: FileHandle?
    private var configurationSignature: String
    private var connectionTask: Task<MCP.Client, Error>?
    private var lastWarmSuccess: Date?
    private let logHandler: @MainActor (LogLevel, String, String) async -> Void
    private var tokensRefreshedObserver: NSObjectProtocol?

    private(set) var state: State = .idle
    private(set) var serverIdentifier: PersistentIdentifier?
    private(set) var processIdentifier: pid_t?
    private var initializedNotificationCount = 0

    var alias: String { server.alias }
    var currentOAuthStatus: OAuthStatus? { server.oauthStatus }
    var shouldKeepConnectionWarm: Bool {
        switch server.kind {
        case .local_stdio:
            return true
        case .remote_http_sse:
            return server.remoteHTTPMode == .httpWithSSE
        }
    }

    init(server: MCPBundler.Server,
         provider: any CapabilitiesProvider,
         logHandler: @escaping @MainActor (LogLevel, String, String) async -> Void) {
        self.server = server
        self.provider = provider
        self.configurationSignature = Self.makeConfigurationSignature(for: server)
        self.logHandler = logHandler
        self.serverIdentifier = server.persistentModelID
        tokensRefreshedObserver = NotificationCenter.default.addObserver(forName: .oauthTokensRefreshed,
                                                                          object: nil,
                                                                          queue: .main) { [weak self] note in
            guard let self,
                  let serverID = note.userInfo?["serverID"] as? String,
                  let currentID = self.serverIdentifier.map({ String(describing: $0) }),
                  serverID == currentID else { return }
            Task { await self.handleTokensRefreshed() }
        }
    }

    deinit {
        if let observer = tokensRefreshedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @discardableResult
    func update(server: MCPBundler.Server,
                provider: any CapabilitiesProvider) async -> Bool {
        let newSignature = Self.makeConfigurationSignature(for: server)
        let configurationChanged = newSignature != configurationSignature
        self.server = server
        self.provider = provider
        self.serverIdentifier = server.persistentModelID
        self.configurationSignature = newSignature

        if configurationChanged {
            await disconnect(reason: .configurationChanged)
        }

        if state == .terminated {
            await transition(to: .idle, message: "reset after update")
        }

        return configurationChanged
    }

    func synchronize(server: MCPBundler.Server, provider: any CapabilitiesProvider) {
        self.server = server
        self.provider = provider
        self.serverIdentifier = server.persistentModelID
    }

    func resetAfterFailure() async {
        await disconnect(reason: .failure)
        if state == .terminated {
            await transition(to: .idle, message: "ready after failure")
        }
        // Attempt background reconnect with simple capped backoff for warm providers
        if shouldKeepConnectionWarm &&
            server.oauthStatus != .unauthorized &&
            server.oauthStatus != .refreshing {
            let delays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch { /* ignore */ }
                do {
                    try await ensureWarmConnection()
                    break
                } catch {
                    continue
                }
            }
        }
    }

    func ensureClient() async throws -> MCP.Client {
        if let client, state == .ready {
            return client
        }

        if let task = connectionTask {
            return try await task.value
        }

        if state == .terminated {
            await transition(to: .idle, message: "reconnecting after termination")
        }

        let task = Task<MCP.Client, Error> { [weak self] in
            guard let self else {
                throw CapabilityError.executionFailed("Upstream provider deallocated")
            }
            return try await self.establishClient()
        }
        connectionTask = task
        await transition(to: .initializing, message: "connecting provider \(alias)")

        do {
            let client = try await task.value
            connectionTask = nil
            self.client = client
            await transition(to: .ready, message: "provider \(alias) ready")
            lastWarmSuccess = Date()
            return client
        } catch {
            connectionTask = nil
            self.client = nil
            await transition(to: .idle,
                             message: "connection failed: \(error.localizedDescription)",
                             level: .error,
                             force: true)
            throw error
        }
    }

    func ensureWarmConnection() async throws {
        if state == .ready {
            return
        }
        _ = try await ensureClient()
    }

    func awaitHintIfNeeded(timeout: TimeInterval = 3.0) async {
        if let exposer = exposedClientProvider() {
            _ = await exposer.awaitHintIfNeeded(timeout: timeout)
        }
    }

    func exposedClientProvider() -> ExposesClient? {
        provider as? ExposesClient
    }

    private func handleTokensRefreshed() async {
        guard server.kind == .remote_http_sse else { return }
        guard let exposes = exposedClientProvider() else { return }
        await exposes.resetRuntimeSession()
        client = nil
        streamingTransport = nil
        httpTransport = nil
        connectionTask?.cancel()
        connectionTask = nil
        state = .terminated
        initializedNotificationCount = 0
        if shouldKeepConnectionWarm {
            do {
                try await ensureWarmConnection()
            } catch {
                // allow retry later via backoff
            }
        }
    }

    func handleAuthenticationChallenge() async {
        OAuthService.shared.markAccessTokenInvalid(for: server)
        if await OAuthService.shared.refreshAccessToken(for: server) == nil {
            await OAuthService.shared.runAuthDiscovery(server: server, wwwAuthenticate: nil)
        }
    }

    func disconnect(reason: UpstreamDisconnectReason) async {
        connectionTask?.cancel()
        connectionTask = nil

        if state != .shuttingDown && state != .terminated {
            await transition(to: .shuttingDown,
                             message: "disconnecting (\(reason.rawValue))",
                             force: true)
        }

        if server.kind == .remote_http_sse, let exposes = exposedClientProvider() {
            await exposes.resetRuntimeSession()
        } else if let currentClient = client {
            await currentClient.disconnect()
        }
        client = nil
        lastWarmSuccess = nil

        if let httpTransport {
            await httpTransport.disconnect()
        }
        httpTransport = nil

        if let streamingTransport {
            await streamingTransport.disconnect()
        }
        streamingTransport = nil

        if let stdioTransport {
            await stdioTransport.disconnect()
        }
        stdioTransport = nil

        if let process = stdioProcess {
            await terminateProcessIfNeeded(process)
        }
        stopStdioStderrCapture()
        stdioProcess = nil
        processIdentifier = nil
        initializedNotificationCount = 0

        await transition(to: .terminated,
                         message: "disconnected (\(reason.rawValue))",
                         force: true)
    }

    private func establishClient() async throws -> MCP.Client {
        if let exposer = provider as? ExposesClient {
            let client = try await exposer.connectAndReturnClient(for: server)
            initializedNotificationCount += 1
            await logHandler(.info,
                             "upstream.lifecycle",
                             "alias=\(alias) event=notificationsInitialized count=\(initializedNotificationCount)")
            return client
        }

        httpTransport = nil
        stdioTransport = nil
        stdioProcess = nil
        processIdentifier = nil
        stopStdioStderrCapture()

        let client = Client(name: "MCPBundler", version: "0.1.0")
        switch server.kind {
        case .local_stdio:
            guard let exec = server.execPath, !exec.isEmpty else {
                throw CapabilityError.invalidConfiguration
            }
            let env = buildEnvironment(for: server)
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if exec.contains("/") {
                process.executableURL = URL(fileURLWithPath: exec)
            } else {
                guard let fullPath = findFullPath(for: exec, using: env) else {
                    throw CapabilityError.executionFailed("Executable '\(exec)' not found in PATH")
                }
                process.executableURL = URL(fileURLWithPath: fullPath)
            }
            process.arguments = server.args
            if let cwd = server.cwd, !cwd.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

            let resolvedExec = process.executableURL?.path ?? exec
            let resolvedCwd = process.currentDirectoryURL?.path ?? ""
            await logHandler(.info,
                             "security.scope",
                             "alias=\(alias) scope=local_stdio exec=\(resolvedExec) cwd=\(resolvedCwd)")

            try process.run()
            processIdentifier = process.processIdentifier
            stdioProcess = process
            startStdioStderrCapture(from: stderrPipe, normalizedAlias: normalizedAliasForLogs(alias))

            let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
            let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
            let transport = StdioTransport(input: inputFD, output: outputFD)
            stdioTransport = transport

            do {
                _ = try await client.connect(transport: transport)
                initializedNotificationCount += 1
                await logHandler(.info,
                                 "upstream.lifecycle",
                                 "alias=\(alias) event=notificationsInitialized count=\(initializedNotificationCount)")
                return client
            } catch {
                await client.disconnect()
                await transport.disconnect()
                await terminateProcessIfNeeded(process)
                stdioTransport = nil
                stdioProcess = nil
                processIdentifier = nil
                stopStdioStderrCapture()
                throw error
            }

        case .remote_http_sse:
            guard let base = server.baseURL, let exposes = provider as? ExposesClient else {
                throw CapabilityError.invalidConfiguration
            }
            await logHandler(.info,
                             "security.scope",
                             "alias=\(alias) scope=remote_http_sse baseURL=\(base)")
            let client = try await exposes.connectAndReturnClient(for: server)
            self.client = client
            streamingTransport = nil
            httpTransport = nil
            initializedNotificationCount += 1
            await logHandler(.info,
                             "upstream.lifecycle",
                             "alias=\(alias) event=notificationsInitialized count=\(initializedNotificationCount)")
            return client
        }
    }

    private func startStdioStderrCapture(from pipe: Pipe, normalizedAlias: String) {
        stopStdioStderrCapture()

        let handle = pipe.fileHandleForReading
        stdioStderrHandle = handle
        let category = "server.\(normalizedAlias).stdio.stderr"

        stdioStderrTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            var pending = Data()
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 4096)
                } catch {
                    break
                }

                guard let chunk, !chunk.isEmpty else { break }
                pending.append(chunk)

                while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = pending.prefix(upTo: newlineIndex)
                    pending.removeSubrange(...newlineIndex)
                    let line = String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.logHandler(.debug, category, line)
                    }
                }
            }

            let remainder = String(decoding: pending, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.logHandler(.debug, category, remainder)
                }
            }
        }
    }

    private func stopStdioStderrCapture() {
        stdioStderrTask?.cancel()
        stdioStderrTask = nil
        stdioStderrHandle?.readabilityHandler = nil
        stdioStderrHandle?.closeFile()
        stdioStderrHandle = nil
    }

    private func normalizedAliasForLogs(_ alias: String) -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unnamed" }
        return trimmed.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
    }


    private func computeOrigin(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else {
            return url.absoluteString
        }
        var value = "\(scheme)://\(host)"
        if let port = url.port {
            let lower = scheme.lowercased()
            let isDefault = (lower == "https" && port == 443) || (lower == "http" && port == 80)
            if !isDefault { value.append(":\(port)") }
        }
        return value
    }

    // Compose HTTP headers for remote MCP, ensuring Authorization is present when OAuth state exists
    private func prepareHeaders(for server: Server, baseURL: URL) async -> [String: String] {
        var headers = buildHeaders(for: server)
        // Always ensure Origin for providers that require it; prefer client_uri from provider metadata
        if let explicit = server.oauthState?.providerMetadata["client_uri"],
           let parsed = URL(string: explicit) {
            headers["Origin"] = computeOrigin(parsed)
        } else {
            headers["Origin"] = computeOrigin(baseURL)
        }

        // If Authorization is missing but we have an OAuth state, attach a fresh token opportunistically
        let hasAuth = headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        if !hasAuth {
            if OAuthService.shared.shouldRefreshAccessToken(for: server) {
                if let token = await OAuthService.shared.refreshAccessToken(for: server) {
                    headers["Authorization"] = "Bearer \(token)"
                }
            } else if let token = OAuthService.shared.resolveAccessToken(for: server) {
                headers["Authorization"] = "Bearer \(token)"
            }
        }
        return headers
    }

    private func transition(to newState: State,
                            message: String,
                            level: LogLevel = .info,
                            force: Bool = false) async {
        if state == newState && !force { return }
        state = newState
        var components: [String] = ["alias=\(alias)", "state=\(newState.rawValue)"]
        if let id = serverIdentifier {
            components.append("serverID=\(String(describing: id))")
        }
        if let pid = processIdentifier, pid != 0 {
            components.append("pid=\(pid)")
        }
        await logHandler(level, "upstream.lifecycle", "\(components.joined(separator: " ")) \(message)")
    }

    private func terminateProcessIfNeeded(_ process: Process) async {
        guard process.isRunning else { return }

        let checkInterval: UInt64 = 100_000_000 // 100ms
        let gracefulTimeout: UInt64 = 2_000_000_000 // 2s

        var waited: UInt64 = 0
        while process.isRunning && waited < gracefulTimeout {
            try? await Task.sleep(nanoseconds: checkInterval)
            waited += checkInterval
        }

        if process.isRunning {
            await logHandler(.info,
                             "upstream.lifecycle",
                             "alias=\(alias) sending SIGTERM pid=\(process.processIdentifier)")
#if canImport(Darwin)
            kill(process.processIdentifier, SIGTERM)
#elseif canImport(Glibc)
            Glibc.kill(process.processIdentifier, Glibc.SIGTERM)
#elseif canImport(Musl)
            Musl.kill(process.processIdentifier, Musl.SIGTERM)
#endif

            waited = 0
            while process.isRunning && waited < gracefulTimeout {
                try? await Task.sleep(nanoseconds: checkInterval)
                waited += checkInterval
            }
        }

        if process.isRunning {
            await logHandler(.error,
                             "upstream.lifecycle",
                             "alias=\(alias) sending SIGKILL pid=\(process.processIdentifier)")
#if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
#elseif canImport(Glibc)
            Glibc.kill(process.processIdentifier, Glibc.SIGKILL)
#elseif canImport(Musl)
            Musl.kill(process.processIdentifier, Musl.SIGKILL)
#endif

            let killTimeout: UInt64 = 500_000_000 // 0.5s
            waited = 0
            while process.isRunning && waited < killTimeout {
                try? await Task.sleep(nanoseconds: checkInterval)
                waited += checkInterval
            }
        }
    }

    private static func makeConfigurationSignature(for server: Server) -> String {
        var parts: [String] = [
            server.kind.rawValue,
            server.execPath ?? "",
            server.cwd ?? "",
            server.args.joined(separator: "|")
        ]

        let overrides = server.envOverrides.map { env -> String in
            let valueComponent = env.plainValue ?? env.keychainRef ?? ""
            return "\(env.key)|\(env.valueSource.rawValue)|\(valueComponent)"
        }.sorted()
        parts.append(overrides.joined(separator: "|"))

        if let project = server.project {
            let projectEnv = project.envVars.map { env -> String in
                let valueComponent = env.plainValue ?? env.keychainRef ?? ""
                return "\(env.key)|\(env.valueSource.rawValue)|\(valueComponent)"
            }.sorted()
            parts.append(projectEnv.joined(separator: "|"))
        } else {
            parts.append("")
        }

        parts.append(server.baseURL ?? "")

        let headers = server.headers.map { header -> String in
            let valueComponent = header.plainValue ?? header.keychainRef ?? ""
            return "\(header.header)|\(header.valueSource.rawValue)|\(valueComponent)"
        }.sorted()
        parts.append(headers.joined(separator: "|"))

        return parts.joined(separator: "||")
    }
}

// Extend CapabilitiesProvider to optionally expose a connected client for reuse.
protocol ExposesClient {
    @MainActor func connectAndReturnClient(for server: Server) async throws -> MCP.Client
    @MainActor func awaitHintIfNeeded(timeout: TimeInterval) async -> Bool
    @MainActor func resetRuntimeSession() async
}

extension ExposesClient {
    @MainActor func awaitHintIfNeeded(timeout: TimeInterval = 0) async -> Bool { false }
    @MainActor func resetRuntimeSession() async {}
}
