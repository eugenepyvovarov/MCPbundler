//
//  BundledServerHost.swift

//  MCP Bundler
//
//  Coordinates the bundled MCP server and exposes a STDIO transport
//  that callers (e.g., CLI helper) can attach to.
//

import Foundation
import MCP
import Logging
import SwiftData
#if canImport(Darwin)
import Darwin
#endif
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

@MainActor
protocol BundledServerHosting: AnyObject {
    func start(project: Project,
               snapshot: BundlerAggregator.Snapshot,
               providers: [Server: any CapabilitiesProvider]) async throws -> StdioTransport?
    func waitForTermination() async throws
    func stop() async
    func reload(project: Project,
                snapshot: BundlerAggregator.Snapshot,
                providers: [Server: any CapabilitiesProvider],
                serverIDs: Set<PersistentIdentifier>?) async throws
    func setPersistenceContext(_ context: ModelContext?)
}

@MainActor
final class BundledServerHost {
    struct Options {
        var preserveProvidersOnTransportClose: Bool = true
        var logLifecycle: Bool = false
        var emitListChangedNotifications: Bool = false

        static let `default` = Options()
    }

    struct TransportFactory {
        let build: @MainActor () throws -> TransportContext

        @MainActor
        static func pipeLoopback() -> TransportFactory {
            TransportFactory {
                let pair = StdioPipePair()
                return TransportContext(from: pair)
            }
        }

        @MainActor
        static func standardIO() -> TransportFactory {
            TransportFactory {
                let transport = BundlerStdioTransport()
                return TransportContext(server: transport, client: nil, storage: nil, shutdown: {})
            }
        }

        @MainActor
        static func inMemoryLoopback() -> (factory: TransportFactory, client: any Transport, teardown: @Sendable () async -> Void) {
            let pair = InMemoryLoopbackPair()
            let factory = TransportFactory {
                TransportContext(server: pair.serverTransport,
                                 client: nil,
                                 storage: pair,
                                 shutdown: pair.shutdown)
            }
            let client = pair.clientTransport
            let teardown = { @Sendable in
                await pair.shutdownAsync()
            }
            return (factory, client, teardown)
        }
    }

    struct TransportContext {
        let server: any Transport
        let client: StdioTransport?
        private let storage: AnyObject?
        private let shutdown: () -> Void

        fileprivate init(server: any Transport, client: StdioTransport?, storage: AnyObject? = nil, shutdown: @escaping () -> Void) {
            self.server = server
            self.client = client
            self.storage = storage
            self.shutdown = shutdown
        }

        fileprivate init(from pair: StdioPipePair) {
            self.init(server: pair.serverTransport,
                      client: pair.clientTransport,
                      storage: pair,
                      shutdown: pair.close)
        }

        fileprivate func teardown() {
            shutdown()
        }

        fileprivate func makeHelperFileHandle() throws -> FileHandle? {
            guard let pair = storage as? StdioPipePair else { return nil }
            return try pair.makeHelperFileHandle()
        }
    }

    private let manager: BundledServerManager
    private let transportFactory: TransportFactory
    private let options: Options
    private var task: Task<Void, Error>?
    private var context: TransportContext?
    private var isSessionActive = false
    private func debugLog(_ message: String) {
        guard options.logLifecycle else { return }
        let formatted = "mcp-bundler.host: \(message)\n"
        if let data = formatted.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private enum SessionEndReason {
        case transportEnded
        case failure(Error)
        case manual
    }

    init(manager: BundledServerManager,
         transportFactory: TransportFactory,
         options: Options = .default) {
        self.manager = manager
        self.transportFactory = transportFactory
        self.options = options
    }

    @MainActor convenience init(transportFactory: TransportFactory,
                                options: Options = .default) {
        self.init(manager: BundledServerManager(listChangedNotificationsEnabled: options.emitListChangedNotifications),
                  transportFactory: transportFactory,
                  options: options)
    }

    @MainActor convenience init(options: Options = .default) {
        self.init(manager: BundledServerManager(listChangedNotificationsEnabled: options.emitListChangedNotifications),
                  transportFactory: .pipeLoopback(),
                  options: options)
    }

    enum HostError: Error {
        case alreadyRunning
    }

    func start(project: Project,
               snapshot: BundlerAggregator.Snapshot,
               providers: [Server: any CapabilitiesProvider]) async throws -> StdioTransport? {
        if task != nil { throw HostError.alreadyRunning }
        debugLog("start requested for project=\(project.name) providers=\(providers.count)")
        try await manager.start(project: project, snapshot: snapshot, providers: providers)
        debugLog("manager.start completed")

        let ctx: TransportContext
        do {
            ctx = try transportFactory.build()
        } catch {
            debugLog("transportFactory.build failed: \(error)")
            await manager.stop()
            throw error
        }

        context = ctx
        isSessionActive = true
        debugLog("session marked active (client available=\(ctx.client != nil))")
        let serving = Task { @MainActor in
            do {
                debugLog("manager.startServing begin")
                try await manager.startServing(transport: ctx.server)
                debugLog("manager.startServing completed")
                await teardownSession(reason: .transportEnded)
            } catch {
                debugLog("manager.startServing threw: \(error)")
                await teardownSession(reason: .failure(error))
                throw error
            }
        }
        task = serving
        debugLog("serving task created")

        return ctx.client
    }

    func waitForTermination() async throws {
        guard let currentTask = task else { return }
        do {
            debugLog("waitForTermination awaiting task")
            try await currentTask.value
            debugLog("waitForTermination completed without error")
        } catch is CancellationError {
            // Ignore cancellation triggered by stop()
            debugLog("waitForTermination caught CancellationError")
        } catch {
            debugLog("waitForTermination caught error: \(error)")
            await teardownSession(reason: .failure(error))
            task = nil
            throw error
        }
        task = nil
    }

    func stop() async {
        debugLog("stop requested")
        let currentTask = task
        currentTask?.cancel()
        await teardownSession(reason: .manual)
        task = nil
    }

    private func teardownSession(reason: SessionEndReason) async {
        guard isSessionActive else { return }
        isSessionActive = false
        debugLog("teardownSession invoked; cancelling context (reason=\(reasonDescription(reason)))")
        context?.teardown()
        context = nil

        let shouldPreserve = {
            switch reason {
            case .transportEnded:
                return options.preserveProvidersOnTransportClose
            case .manual, .failure:
                return false
            }
        }()

        if shouldPreserve {
            debugLog("preserving providers after transport end")
            return
        }

        await manager.stop()
        debugLog("manager.stop completed")
    }

    func makeHelperFileHandle() -> FileHandle? {
        do {
            return try context?.makeHelperFileHandle() ?? nil
        } catch {
            return nil
        }
    }

    func reload(project: Project,
                snapshot: BundlerAggregator.Snapshot,
                                   providers: [Server: any CapabilitiesProvider],
                serverIDs: Set<PersistentIdentifier>? = nil) async throws {
        debugLog("reload invoked; targetedIDs=\(serverIDs?.count ?? 0)")
        try await manager.reload(project: project,
                                  snapshot: snapshot,
                                  providers: providers,
                                  serverIDs: serverIDs)
    }

    func setPersistenceContext(_ context: ModelContext?) {
        manager.setPersistenceContext(context)
    }

    private func reasonDescription(_ reason: SessionEndReason) -> String {
        switch reason {
        case .transportEnded:
            return "transportEnded"
        case .manual:
            return "manual"
        case .failure(let error):
            return "failure(\(error.localizedDescription))"
        }
    }
}

@MainActor
extension BundledServerHost: BundledServerHosting {}

/// Internal helper that wires up a pair of STDIO transports backed by pipes.
@MainActor
final class StdioPipePair {
    let serverTransport: StdioTransport
    let clientTransport: StdioTransport
    private let serverReadFD: Int32
    private let serverWriteFD: Int32
    private let clientReadFD: Int32
    private let clientWriteFD: Int32

    init() {
        var sockets: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0, "socketpair failed")

        let serverFD = sockets[0]
        let clientFD = sockets[1]

        let duplicatedServerRead = dup(serverFD)
        precondition(duplicatedServerRead >= 0, "dup failed for server read")
        let duplicatedClientRead = dup(clientFD)
        precondition(duplicatedClientRead >= 0, "dup failed for client read")

        self.serverReadFD = duplicatedServerRead
        self.serverWriteFD = serverFD
        self.clientReadFD = duplicatedClientRead
        self.clientWriteFD = clientFD

        let serverInput = FileDescriptor(rawValue: serverReadFD)
        let serverOutput = FileDescriptor(rawValue: serverWriteFD)
        self.serverTransport = StdioTransport(input: serverInput, output: serverOutput)

        let clientInput = FileDescriptor(rawValue: clientReadFD)
        let clientOutput = FileDescriptor(rawValue: clientWriteFD)
        self.clientTransport = StdioTransport(input: clientInput, output: clientOutput)
    }

    func makeHelperFileHandle() throws -> FileHandle {
        let duplicated = dup(clientWriteFD)
        guard duplicated >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF)
        }
        return FileHandle(fileDescriptor: duplicated, closeOnDealloc: true)
    }

    func close() {
        _ = Darwin.close(serverReadFD)
        _ = Darwin.close(serverWriteFD)
        _ = Darwin.close(clientReadFD)
        _ = Darwin.close(clientWriteFD)
    }
}

@MainActor
private final class InMemoryLoopbackPair: @unchecked Sendable {
    let serverTransport: InMemoryDuplexTransport
    let clientTransport: InMemoryDuplexTransport

    init() {
        let server = InMemoryDuplexTransport(label: "mcp.bundler.inmemory.server")
        let client = InMemoryDuplexTransport(label: "mcp.bundler.inmemory.client")
        self.serverTransport = server
        self.clientTransport = client

        Task { [weak server, weak client] in
            guard let server, let client else { return }
            await server.setPeer(client)
            await client.setPeer(server)
        }
    }

    func shutdown() {
        Task {
            await serverTransport.disconnect()
            await clientTransport.disconnect()
        }
    }

    func shutdownAsync() async {
        await serverTransport.disconnect()
        await clientTransport.disconnect()
    }
}

private actor InMemoryDuplexTransport: Transport {
    nonisolated let logger: Logger

    private var peer: InMemoryDuplexTransport?
    private var streamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Swift.Error>?
    private var isConnected = false

    init(label: String) {
        self.logger = Logger(label: label) { _ in SwiftLogNoOpLogHandler() }
    }

    func setPeer(_ peer: InMemoryDuplexTransport) {
        self.peer = peer
    }

    func connect() async throws {
        isConnected = true
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        streamContinuation?.finish()
        streamContinuation = nil
        stream = nil
    }

    func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(POSIXError(.ENOTCONN))
        }
        guard let peer else {
            throw MCPError.transportError(POSIXError(.ENOTCONN))
        }
        await peer.receive(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        if let stream {
            return stream
        }

        let created = AsyncThrowingStream<Data, Swift.Error> { continuation in
            self.streamContinuation = continuation
        }
        stream = created
        return created
    }

    private func receive(_ data: Data) {
        streamContinuation?.yield(data)
    }
}
