import Foundation
import Observation
import MCP
import SwiftData

struct StdiosessionStartResult {
    let transport: StdioTransport?
    let helperHandle: FileHandle?
}

@MainActor
protocol StdiosessionRunning: AnyObject {
    func begin() async throws -> StdiosessionStartResult
    func waitForTermination() async throws
    func stop() async
    func reload(projectID: PersistentIdentifier?, serverIDs: Set<PersistentIdentifier>?) async
}

@MainActor
public protocol StdiosessionControlling: AnyObject {
    var isRunning: Bool { get }
    func startPreviewSession() async throws
    func stopPreviewSession() async
    func reload(projectID: PersistentIdentifier?, serverIDs: Set<PersistentIdentifier>?) async
}

@Observable
@MainActor
public final class StdiosessionController: StdiosessionControlling {
    public enum ControllerError: Error {
        case sessionAlreadyActive
        case transportUnavailable
    }

    private enum ActiveSession {
        case none
        case preview(StdiosessionRunning)
    }

    public var isRunning: Bool = false

    private let previewRunnerFactory: () -> StdiosessionRunning
    private var activeSession: ActiveSession = .none

    init(previewRunnerFactory: @escaping () -> StdiosessionRunning) {
        self.previewRunnerFactory = previewRunnerFactory
    }

    public func startPreviewSession() async throws {
        guard case .none = activeSession else { throw ControllerError.sessionAlreadyActive }
        let runner = previewRunnerFactory()
        _ = try await runner.begin()
        isRunning = true
        activeSession = .preview(runner)
    }

    public func stopPreviewSession() async {
        guard case let .preview(runner) = activeSession else { return }
        await runner.stop()
        isRunning = false
        activeSession = .none
    }

    public func reload(projectID: PersistentIdentifier? = nil, serverIDs: Set<PersistentIdentifier>? = nil) async {
        guard case let .preview(runner) = activeSession else { return }
        await runner.reload(projectID: projectID, serverIDs: serverIDs)
    }

    static func live(container: ModelContainer) -> StdiosessionController {
        return StdiosessionController {
            BundledRunnerSession(container: container, hostFactory: .pipeLoopback())
        }
    }
}

@MainActor
final class BundledRunnerSession: StdiosessionRunning {
    private let host: BundledServerHost
    private let runner: StdioBundlerRunner

    init(container: ModelContainer, hostFactory: BundledServerHost.TransportFactory) {
        let host = BundledServerHost(transportFactory: hostFactory)
        self.host = host
        self.runner = StdioBundlerRunner(container: container, host: host)
    }

    func begin() async throws -> StdiosessionStartResult {
        let transport = try await runner.start()
        let helperHandle = host.makeHelperFileHandle()
        return StdiosessionStartResult(transport: transport, helperHandle: helperHandle)
    }

    func waitForTermination() async throws {
        try await runner.waitForTermination()
    }

    func stop() async {
        await runner.stop()
    }

    func reload(projectID: PersistentIdentifier?, serverIDs: Set<PersistentIdentifier>?) async {
        await runner.reload(projectID: projectID, serverIDs: serverIDs)
    }
}
