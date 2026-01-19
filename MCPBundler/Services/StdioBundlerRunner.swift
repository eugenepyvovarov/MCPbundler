//
//  StdioBundlerRunner.swift
//  MCP Bundler
//
//  Boots the bundled server using the active project and serves it over STDIO.
//

import Foundation
import SwiftData
import MCP

@MainActor
final class StdioBundlerRunner {
    enum RunnerError: LocalizedError {
        case noActiveProject
        case noServers
        case missingSnapshot
        case snapshotUnavailable

        var errorDescription: String? {
            switch self {
            case .noActiveProject:
                return "No active project is set. Activate a project before starting the STDIO server."
            case .noServers:
                return "The active project has no servers configured."
            case .missingSnapshot:
                return "Cached capabilities are not available. Open the app to rebuild the project snapshot."
            case .snapshotUnavailable:
                return "Cached snapshot is still rebuilding. Retry once capabilities generation completes."
            }
        }
    }

    private let container: ModelContainer
    private let host: BundledServerHosting
    private let providerResolver: @MainActor (Server) -> any CapabilitiesProvider
    private var context: ModelContext?
    private var currentProjectID: PersistentIdentifier?
    private let logLifecycle: Bool
    private var cachedSnapshot: BundlerAggregator.Snapshot?
    private var cachedSnapshotRevision: Int64?
    private func logInfo(_ message: String) {
        guard logLifecycle else { return }
        let formatted = "mcp-bundler.runner: \(message)\n"
        if let data = formatted.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    init(container: ModelContainer,
         host: BundledServerHosting,
         logLifecycle: Bool = false,
         providerResolver: @escaping @MainActor (Server) -> any CapabilitiesProvider = { server in
             CapabilitiesService.provider(for: server)
         }) {
        self.container = container
        self.host = host
        self.logLifecycle = logLifecycle
        self.providerResolver = providerResolver
    }

    func start() async throws -> StdioTransport? {
        logInfo("start invoked")
        let context = ModelContext(container)
        self.context = context
        host.setPersistenceContext(context)

        guard let project = try fetchActiveProject(using: context) else { throw RunnerError.noActiveProject }
        guard !project.servers.isEmpty else { throw RunnerError.noServers }
        currentProjectID = project.persistentModelID

        let snapshot = try await loadSnapshot(for: project)

        let providers = makeProviders(for: project)
        let transport = try await host.start(project: project, snapshot: snapshot, providers: providers)
        logInfo("start completed (transport=\(transport != nil ? "loopback" : "stdio"))")
        return transport
    }

    func waitForTermination() async throws {
        logInfo("waitForTermination requested")
        try await host.waitForTermination()
        logInfo("waitForTermination finished")
    }

    func stop() async {
        logInfo("stop invoked")
        await host.stop()
        // Clear persistence context only when actually stopping
        host.setPersistenceContext(nil)
        context = nil
        currentProjectID = nil
        cachedSnapshot = nil
        cachedSnapshotRevision = nil
        logInfo("stop completed; context cleared")
    }

    func reload(projectID: PersistentIdentifier? = nil, serverIDs: Set<PersistentIdentifier>? = nil) async {
        logInfo("reload requested projectFilter=\(projectID != nil) serverFilter=\(serverIDs?.count ?? 0)")
        guard let context else { return }

        guard let project = try? fetchActiveProject(using: context) else {
            logWarning("Reload skipped: no active project found.")
            return
        }

        let activeID = project.persistentModelID

        currentProjectID = activeID

        if let expectedProjectID = projectID, expectedProjectID != activeID {
            return
        }

        let snapshot: BundlerAggregator.Snapshot
        do {
            snapshot = try await loadSnapshot(for: project)
        } catch {
            logWarning("Reload skipped: failed to load snapshot. Error: \(error)")
            return
        }

        let providers = makeProviders(for: project)

        do {
            try await host.reload(project: project,
                                   snapshot: snapshot,
                                   providers: providers,
                                   serverIDs: serverIDs)
            logInfo("reload completed")
        } catch {
            logWarning("Failed to reload bundled server: \(error)")
        }
    }

    private func fetchActiveProject(using context: ModelContext) throws -> Project? {
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.isActive })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func makeProviders(for project: Project) -> [Server: any CapabilitiesProvider] {
        var map: [Server: any CapabilitiesProvider] = [:]
        for server in project.servers {
            guard server.isEnabled else { continue }
            map[server] = providerResolver(server)
        }
        return map
    }

    private func loadSnapshot(for project: Project) async throws -> BundlerAggregator.Snapshot {
        await ProjectSnapshotCache.ensureSnapshot(for: project)

        let revision = project.snapshotRevision
        if let cachedSnapshot, cachedSnapshotRevision == revision {
            return cachedSnapshot
        }

        var attempt = 0
        var delay: TimeInterval = 0.25
        let maxDelay: TimeInterval = 5
        var elapsed: TimeInterval = 0
        let maxElapsed: TimeInterval = 30

        while true {
            do {
                let snapshot = try ProjectSnapshotCache.snapshot(for: project)
                cachedSnapshot = snapshot
                cachedSnapshotRevision = revision
                return snapshot
            } catch let decodingError as DecodingError {
                logWarning("Snapshot decode failed for project \(project.name): \(decodingError)")
                throw RunnerError.missingSnapshot
            } catch {
                if elapsed >= maxElapsed {
                    break
                }

                let wait = min(delay, maxElapsed - elapsed)
                attempt += 1
                logWarning("Cached snapshot unavailable for project \(project.name); retrying in \(String(format: "%.2f", wait))s (attempt \(attempt)).")
                await ProjectSnapshotCache.ensureSnapshot(for: project)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    elapsed += wait
                }
                delay = min(delay * 2, maxDelay)
            }
        }

        throw RunnerError.snapshotUnavailable
    }

    private func logWarning(_ message: String) {
        let formatted = "mcp-bundler: \(message)\n"
        if let data = formatted.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

}
