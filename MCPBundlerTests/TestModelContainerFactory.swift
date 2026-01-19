import Foundation
import MCP
import SwiftData
import Logging
@testable import MCPBundler

enum TestModelContainerFactory {
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: MCPBundlerSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema,
                                           migrationPlan: MCPBundlerMigrationPlan.self,
                                           configurations: [configuration])
        try OAuthMigration.performInitialBackfill(in: container)
        return container
    }

    static func makePersistentContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: MCPBundlerSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema,
                                           migrationPlan: MCPBundlerMigrationPlan.self,
                                           configurations: [configuration])
        try OAuthMigration.performInitialBackfill(in: container)
        return container
    }
}

enum TestCapabilitiesBuilder {
    @discardableResult
    static func prime(server: MCPBundler.Server,
                      capabilities: MCPCapabilities? = nil,
                      generatedAt: Date = Date()) throws -> MCPCapabilities {
        let caps = capabilities ?? makeDefaultCapabilities(for: server)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(caps)

        server.capabilityCaches.removeAll()
        server.capabilityCaches.append(CapabilityCache(server: server,
                                                       payload: data,
                                                       generatedAt: generatedAt))
        return caps
    }

    static func makeDefaultCapabilities(for server: MCPBundler.Server) -> MCPCapabilities {
        let tools = [
            MCPTool(name: "search", description: "Mock search tool"),
            MCPTool(name: "scrape", description: "Mock scrape tool")
        ]
        return MCPCapabilities(serverName: server.alias.capitalized,
                                serverDescription: "Mock server for tests",
                                tools: tools,
                                resources: nil,
                                prompts: nil)
    }
}

@MainActor
final class RecordingUpstreamProvider: UpstreamProviding {
    private var server: MCPBundler.Server
    private let keepWarm: Bool
    private var signature: String
    private var client: Client?
    private var transport: InMemoryTransport?
    private let logSink: BundledServerManager.LogSink?

    private(set) var warmUpCount = 0
    private(set) var resetCount = 0
    private(set) var disconnectReasons: [UpstreamDisconnectReason] = []
    var nextWarmUpError: Error?
    var stubbedResponses: [String: [String: Any]] = [:]
    private var notificationCount = 0

    init(server: MCPBundler.Server,
         keepWarm: Bool,
         logSink: BundledServerManager.LogSink? = nil) {
        self.server = server
        self.keepWarm = keepWarm
        self.signature = RecordingUpstreamProvider.makeSignature(for: server)
        self.logSink = logSink
    }

    var alias: String { server.alias }
    var shouldKeepConnectionWarm: Bool { keepWarm }
    var serverIdentifier: PersistentIdentifier? { server.persistentModelID }

    func update(server: MCPBundler.Server, provider: any CapabilitiesProvider) async -> Bool {
        let newSignature = RecordingUpstreamProvider.makeSignature(for: server)
        let changed = newSignature != signature
        self.server = server
        self.signature = newSignature
        if changed {
            await disconnect(reason: .configurationChanged)
        }
        return changed
    }

    func synchronize(server: MCPBundler.Server, provider: any CapabilitiesProvider) {
        self.server = server
        self.signature = RecordingUpstreamProvider.makeSignature(for: server)
    }

    func ensureClient() async throws -> Client {
        if let client { return client }
        let client = Client(name: "Test-\(alias)", version: "1.0.0")
        let transport = InMemoryTransport()
        await transport.setResponses(stubbedResponses)
        _ = try await client.connect(transport: transport)
        self.client = client
        self.transport = transport
        switch server.kind {
        case .local_stdio:
            await log(.info,
                      category: "security.scope",
                      message: "alias=\(alias) scope=local_stdio exec=\(server.execPath ?? "") cwd=\(server.cwd ?? "")")
        case .remote_http_sse:
            await log(.info,
                      category: "security.scope",
                      message: "alias=\(alias) scope=remote_http_sse baseURL=\(server.baseURL ?? "")")
        }
        notificationCount += 1
        await log(.info,
                  category: "upstream.lifecycle",
                  message: "alias=\(alias) event=notificationsInitialized count=\(notificationCount)")
        return client
    }

    func ensureWarmConnection() async throws {
        warmUpCount += 1
        if let error = nextWarmUpError {
            nextWarmUpError = nil
            throw error
        }
        await log(.info, category: "upstream.lifecycle", message: "alias=\(alias) state=ready")
    }

    func resetAfterFailure() async {
        resetCount += 1
    }

    func disconnect(reason: UpstreamDisconnectReason) async {
        disconnectReasons.append(reason)
        await log(.info, category: "upstream.lifecycle", message: "alias=\(alias) state=terminated reason=\(reason.rawValue)")
        await transport?.disconnect()
        transport = nil
        client = nil
        notificationCount = 0
    }

    func updateResponses(_ responses: [String: [String: Any]]) async {
        stubbedResponses = responses
        await transport?.setResponses(responses)
    }

    func observedMethodCalls() async -> [String] {
        await transport?.methodNames() ?? []
    }

    private func log(_ level: LogLevel, category: String, message: String) async {
        guard let logSink else { return }
        await logSink(level, category, message)
    }

    private static func makeSignature(for server: MCPBundler.Server) -> String {
        [
            server.kind.rawValue,
            server.execPath ?? "",
            server.cwd ?? "",
            server.args.joined(separator: "|"),
            server.baseURL ?? ""
        ].joined(separator: "||")
    }
}

private actor InMemoryTransport: Transport {
    nonisolated let logger = Logger(label: "test.transport")
    private var isConnected = false
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Swift.Error>?
    private var responses: [String: [String: Any]] = [:]
    private var receivedMethods: [String] = []

    func connect() async throws {
        isConnected = true
    }

    func disconnect() async {
        isConnected = false
        continuation?.finish()
        continuation = nil
        stream = nil
    }

    func send(_ data: Data) async throws {
        guard isConnected else { throw MCPError.transportError(POSIXError(.ENOTCONN)) }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"],
            let method = json["method"] as? String
        else { return }

        receivedMethods.append(method)

        let response: [String: Any]
        if method == Initialize.name {
            response = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": Version.latest,
                    "capabilities": [String: Any](),
                    "serverInfo": ["name": "StubServer", "version": "1.0.0"]
                ]
            ]
        } else if method == "shutdown" {
            response = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [:]
            ]
        } else {
            let payload = responses[method] ?? [:]
            response = [
                "jsonrpc": "2.0",
                "id": id,
                "result": payload
            ]
        }

        guard let responseData = try? JSONSerialization.data(withJSONObject: response) else { return }
        continuation?.yield(responseData)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        if let stream {
            return stream
        }

        let created = AsyncThrowingStream<Data, Swift.Error> { continuation in
            self.continuation = continuation
        }
        stream = created
        return created
    }

    func setResponses(_ responses: [String: [String: Any]]) {
        self.responses = responses
    }

    func methodNames() -> [String] {
        receivedMethods
    }
}
