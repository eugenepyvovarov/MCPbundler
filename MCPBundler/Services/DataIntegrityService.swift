import Foundation
import SwiftData
import MCP

struct IntegrityReportSummary: Equatable {
    let duplicateAliasCount: Int
    let orphanEnvVarCount: Int
    let duplicateCacheCount: Int
    let invalidCacheCount: Int
    let duplicateCapabilityNameCount: Int
    let corruptServerCount: Int
}

@MainActor
final class DataIntegrityService {
    struct DuplicateAliasGroup {
        let project: Project
        let normalizedAlias: String
        let servers: [Server]

        var preferredAlias: String {
            let trimmed = servers.first?.alias.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? normalizedAlias : trimmed
        }
    }

    struct DuplicateCapabilityNames {
        let server: Server
        let toolNames: [String]
        let promptNames: [String]
        let resourceNames: [String]

        var totalCount: Int {
            toolNames.count + promptNames.count + resourceNames.count
        }
    }

    struct ScanReport {
        let duplicateAliasGroups: [DuplicateAliasGroup]
        let orphanEnvVars: [EnvVar]
        let serversWithDuplicateCaches: [Server]
        let invalidCacheServers: [Server]
        let duplicateCapabilityServers: [DuplicateCapabilityNames]
        let corruptServerIDs: Set<PersistentIdentifier>
        let affectedServerIDs: Set<PersistentIdentifier>
        let affectedProjectIDs: Set<PersistentIdentifier>
        let affectedProjects: [Project]
        let summary: IntegrityReportSummary

        var isClean: Bool {
            duplicateAliasGroups.isEmpty
                && orphanEnvVars.isEmpty
                && serversWithDuplicateCaches.isEmpty
                && invalidCacheServers.isEmpty
                && duplicateCapabilityServers.isEmpty
        }
    }

    struct RepairOutcome {
        let backupURLs: [URL]
        let remainingIssues: ScanReport?
    }

    private let context: ModelContext
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(context: ModelContext) {
        self.context = context
    }

    func scan() -> ScanReport {
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let orphanEnvVars = fetchOrphanEnvVars()

        var duplicateAliasGroups: [DuplicateAliasGroup] = []
        var serversWithDuplicateCaches: [Server] = []
        var invalidCacheServers: [Server] = []
        var duplicateCapabilityServers: [DuplicateCapabilityNames] = []
        var corruptServerIDs = Set<PersistentIdentifier>()
        var affectedServerIDs = Set<PersistentIdentifier>()
        var affectedProjectIDs = Set<PersistentIdentifier>()
        var affectedProjects: [PersistentIdentifier: Project] = [:]

        var duplicateAliasCount = 0
        var duplicateCacheCount = 0
        var invalidCacheCount = 0
        var duplicateCapabilityNameCount = 0
        var invalidCacheCountsByServer: [PersistentIdentifier: Int] = [:]

        for project in projects {
            let aliasGroups = Dictionary(grouping: project.servers, by: { normalizedAlias($0.alias) })
            for (normalized, servers) in aliasGroups where servers.count > 1 {
                let sorted = sortServersStable(servers)
                duplicateAliasGroups.append(DuplicateAliasGroup(project: project,
                                                               normalizedAlias: normalized,
                                                               servers: sorted))
                duplicateAliasCount += max(servers.count - 1, 0)
                affectedProjectIDs.insert(project.persistentModelID)
                affectedProjects[project.persistentModelID] = project
                for server in servers {
                    affectedServerIDs.insert(server.persistentModelID)
                }
            }

            for server in project.servers {
                let caches = server.capabilityCaches.sorted { $0.generatedAt > $1.generatedAt }
                if caches.count > 1 {
                    serversWithDuplicateCaches.append(server)
                    duplicateCacheCount += caches.count - 1
                    affectedServerIDs.insert(server.persistentModelID)
                    affectedProjectIDs.insert(project.persistentModelID)
                    affectedProjects[project.persistentModelID] = project
                }

                var latestCapabilities: MCPCapabilities?
                for (index, cache) in caches.enumerated() {
                    if let decoded = decodeCapabilities(from: cache) {
                        if index == 0 {
                            latestCapabilities = decoded
                        }
                    } else {
                        invalidCacheCount += 1
                        invalidCacheCountsByServer[server.persistentModelID, default: 0] += 1
                        if index == 0 {
                            invalidCacheServers.append(server)
                            corruptServerIDs.insert(server.persistentModelID)
                            affectedServerIDs.insert(server.persistentModelID)
                            affectedProjectIDs.insert(project.persistentModelID)
                            affectedProjects[project.persistentModelID] = project
                        }
                    }
                }

                if let latestCapabilities {
                    let toolDuplicates = duplicateNames(in: latestCapabilities.tools.map(\.name))
                    let promptDuplicates = duplicateNames(in: latestCapabilities.prompts?.map(\.name) ?? [])
                    let resourceDuplicates = duplicateNames(in: latestCapabilities.resources?.map(\.name) ?? [])
                    if !toolDuplicates.isEmpty || !promptDuplicates.isEmpty || !resourceDuplicates.isEmpty {
                        duplicateCapabilityServers.append(DuplicateCapabilityNames(server: server,
                                                                                  toolNames: toolDuplicates,
                                                                                  promptNames: promptDuplicates,
                                                                                  resourceNames: resourceDuplicates))
                        duplicateCapabilityNameCount += toolDuplicates.count
                        duplicateCapabilityNameCount += promptDuplicates.count
                        duplicateCapabilityNameCount += resourceDuplicates.count
                        corruptServerIDs.insert(server.persistentModelID)
                        affectedServerIDs.insert(server.persistentModelID)
                        affectedProjectIDs.insert(project.persistentModelID)
                        affectedProjects[project.persistentModelID] = project
                    }
                }
            }
        }

        for env in orphanEnvVars {
            if let project = env.project {
                affectedProjectIDs.insert(project.persistentModelID)
                affectedProjects[project.persistentModelID] = project
            }
        }

        let summary = IntegrityReportSummary(duplicateAliasCount: duplicateAliasCount,
                                             orphanEnvVarCount: orphanEnvVars.count,
                                             duplicateCacheCount: duplicateCacheCount,
                                             invalidCacheCount: invalidCacheCount,
                                             duplicateCapabilityNameCount: duplicateCapabilityNameCount,
                                             corruptServerCount: corruptServerIDs.count)

        let report = ScanReport(duplicateAliasGroups: duplicateAliasGroups,
                                orphanEnvVars: orphanEnvVars,
                                serversWithDuplicateCaches: serversWithDuplicateCaches,
                                invalidCacheServers: invalidCacheServers,
                                duplicateCapabilityServers: duplicateCapabilityServers,
                                corruptServerIDs: corruptServerIDs,
                                affectedServerIDs: affectedServerIDs,
                                affectedProjectIDs: affectedProjectIDs,
                                affectedProjects: Array(affectedProjects.values),
                                summary: summary)

        if !report.isClean {
            logScan(report, invalidCacheCounts: invalidCacheCountsByServer)
            if context.hasChanges {
                try? context.save()
            }
        }

        return report
    }

    func repair(report: ScanReport, storeURL: URL) -> RepairOutcome {
        var backupURLs: [URL] = []

        do {
            backupURLs = try createBackup(for: storeURL)
            logToProjects(report.affectedProjects,
                          message: "Created sqlite backup at \(backupURLs[0].path).",
                          category: "integrity.repair",
                          level: .info)
        } catch {
            logToProjects(report.affectedProjects,
                          message: "Failed to create sqlite backup: \(error.localizedDescription)",
                          category: "integrity.repair",
                          level: .error)
        }

        if !report.duplicateAliasGroups.isEmpty {
            for group in report.duplicateAliasGroups {
                let baseAlias = group.preferredAlias
                let sorted = sortServersStable(group.servers)
                guard let keeper = sorted.first else { continue }
                for server in sorted where server !== keeper {
                    let newAlias = makeUniqueAlias(baseAlias, in: group.project)
                    let oldAlias = server.alias
                    server.alias = newAlias
                    group.project.markUpdated()
                    log("Renamed duplicate alias from '\(oldAlias)' to '\(newAlias)'.",
                        category: "integrity.repair",
                        project: group.project,
                        metadata: metadataForServer(server))
                }
            }
        }

        if !report.orphanEnvVars.isEmpty {
            for env in report.orphanEnvVars {
                if let project = env.project {
                    project.envVars.removeAll { $0 === env }
                    project.markUpdated()
                }
                context.delete(env)
            }
            logToProjects(report.affectedProjects,
                          message: "Removed \(report.orphanEnvVars.count) orphan environment variable(s).",
                          category: "integrity.repair",
                          level: .info)
        }

        let corruptServers = Set(report.corruptServerIDs)
        for server in report.serversWithDuplicateCaches {
            guard !corruptServers.contains(server.persistentModelID) else { continue }
            let kept = server.pruneCapabilityCaches(keepingLatestIn: context)
            if kept != nil {
                log("Pruned extra capability caches for alias=\(server.alias).",
                    category: "integrity.repair",
                    project: server.project,
                    metadata: metadataForServer(server))
            }
        }

        var handledCorruptServers = Set<PersistentIdentifier>()
        for server in report.invalidCacheServers {
            if handledCorruptServers.insert(server.persistentModelID).inserted {
                clearAndDisableCorruptServer(server)
            }
        }
        for entry in report.duplicateCapabilityServers {
            if handledCorruptServers.insert(entry.server.persistentModelID).inserted {
                clearAndDisableCorruptServer(entry.server)
            }
        }

        for project in report.affectedProjects {
            project.cachedSnapshot = nil
            project.cachedSnapshotVersion = nil
            project.cachedSnapshotGeneratedAt = nil
            ProjectSnapshotCache.clearCache(for: project)
        }

        if context.hasChanges {
            try? context.save()
        }

        let postReport = scan()
        if postReport.isClean {
            deleteBackup(backupURLs)
            logToProjects(report.affectedProjects,
                          message: "Integrity repair completed; backup removed.",
                          category: "integrity.repair",
                          level: .info)
        } else {
            logToProjects(report.affectedProjects,
                          message: "Integrity repair completed with remaining issues.",
                          category: "integrity.repair",
                          level: .error)
        }

        if context.hasChanges {
            try? context.save()
        }

        return RepairOutcome(backupURLs: backupURLs, remainingIssues: postReport.isClean ? nil : postReport)
    }

    func logUserDecisionContinue(report: ScanReport) {
        logToProjects(report.affectedProjects,
                      message: "User continued without running integrity repair.",
                      category: "integrity.repair",
                      level: .info)
        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Scan helpers

    private func fetchOrphanEnvVars() -> [EnvVar] {
        let descriptor = FetchDescriptor<EnvVar>(predicate: #Predicate { $0.server == nil })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func decodeCapabilities(from cache: CapabilityCache) -> MCPCapabilities? {
        try? decoder.decode(MCPCapabilities.self, from: cache.payload)
    }

    private func duplicateNames(in names: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for name in names {
            if !seen.insert(name).inserted {
                duplicates.insert(name)
            }
        }
        return Array(duplicates).sorted()
    }

    private func normalizedAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sortServersStable(_ servers: [Server]) -> [Server] {
        servers.sorted { lhs, rhs in
            let comparison = lhs.alias.localizedCaseInsensitiveCompare(rhs.alias)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
        }
    }

    private func summarizeDuplicates(_ names: [String]) -> String {
        guard !names.isEmpty else { return "none" }
        let limit = 5
        let trimmed = names.prefix(limit)
        let suffix = names.count > limit ? ", ..." : ""
        return trimmed.joined(separator: ", ") + suffix
    }

    // MARK: - Logging

    private func logScan(_ report: ScanReport, invalidCacheCounts: [PersistentIdentifier: Int]) {
        for group in report.duplicateAliasGroups {
            let aliases = group.servers.map(\.alias).joined(separator: ", ")
            log("Duplicate alias '\(group.preferredAlias)' found in project '\(group.project.name)': \(aliases).",
                category: "integrity.scan",
                project: group.project,
                metadata: metadataForAlias(group.preferredAlias))
        }

        for env in report.orphanEnvVars {
            let message = "Orphan env var '\(env.key)' has no server association."
            log(message, category: "integrity.scan", project: env.project, metadata: ["env_key": env.key])
        }

        for server in report.serversWithDuplicateCaches {
            let cacheCount = server.capabilityCaches.count
            log("Server alias=\(server.alias) has \(cacheCount) capability caches; keeping newest.",
                category: "integrity.scan",
                project: server.project,
                metadata: metadataForServer(server))
        }

        for server in report.invalidCacheServers {
            let count = invalidCacheCounts[server.persistentModelID] ?? 1
            log("Server alias=\(server.alias) has \(count) invalid capability cache payload(s).",
                category: "integrity.scan",
                project: server.project,
                metadata: metadataForServer(server))
        }

        for entry in report.duplicateCapabilityServers {
            let toolSummary = summarizeDuplicates(entry.toolNames)
            let promptSummary = summarizeDuplicates(entry.promptNames)
            let resourceSummary = summarizeDuplicates(entry.resourceNames)
            let message = "Server alias=\(entry.server.alias) has duplicate capability names " +
                "(tools: \(toolSummary); prompts: \(promptSummary); resources: \(resourceSummary))."
            log(message,
                category: "integrity.scan",
                project: entry.server.project,
                metadata: metadataForServer(entry.server))
        }
    }

    private func logToProjects(_ projects: [Project],
                               message: String,
                               category: String,
                               level: LogLevel) {
        guard !projects.isEmpty else {
            AppDelegate.writeToStderr("mcp-bundler: \(message)\n")
            return
        }
        for project in projects {
            log(message, category: category, level: level, project: project, metadata: nil)
        }
    }

    private func log(_ message: String,
                     category: String,
                     level: LogLevel = .info,
                     project: Project?,
                     metadata: [String: String]?) {
        let metadataData = metadata.flatMap { try? encoder.encode($0) }
        let entry = LogEntry(project: project,
                             timestamp: Date(),
                             level: level,
                             category: category,
                             message: message,
                             metadata: metadataData)
        context.insert(entry)
    }

    private func metadataForServer(_ server: Server) -> [String: String] {
        let trimmed = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeAliasForMetadata(trimmed)
        return [
            "alias": trimmed,
            "alias_normalized": normalized
        ]
    }

    private func metadataForAlias(_ alias: String) -> [String: String] {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeAliasForMetadata(trimmed)
        return [
            "alias": trimmed,
            "alias_normalized": normalized
        ]
    }

    private func normalizeAliasForMetadata(_ alias: String) -> String {
        alias.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#,
                                   with: "-",
                                   options: .regularExpression)
    }

    // MARK: - Repair helpers

    private func clearAndDisableCorruptServer(_ server: Server) {
        let hint = "Disable server and refresh capabilities after fixing upstream data."
        if server.isEnabled {
            server.isEnabled = false
            server.project?.markUpdated()
            log("Disabled server alias=\(server.alias) due to corrupt capabilities. \(hint)",
                category: "integrity.server",
                level: .info,
                project: server.project,
                metadata: metadataForServer(server))
        }
        server.clearCapabilityCaches(in: context)
        log("Cleared capability cache for alias=\(server.alias).",
            category: "integrity.repair",
            project: server.project,
            metadata: metadataForServer(server))
    }

    private func makeUniqueAlias(_ alias: String, in project: Project) -> String {
        let sanitized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return fallbackAlias(in: project) }
        if !project.servers.contains(where: { candidate in
            candidate.alias.compare(sanitized, options: [.caseInsensitive]) == .orderedSame
        }) {
            return sanitized
        }
        var counter = 2
        while true {
            let candidate = "\(sanitized)-\(counter)"
            if !project.servers.contains(where: { existing in
                existing.alias.compare(candidate, options: [.caseInsensitive]) == .orderedSame
            }) {
                return candidate
            }
            counter += 1
        }
    }

    private func fallbackAlias(in project: Project) -> String {
        var counter = 1
        while true {
            let candidate = "imported-server-\(counter)"
            if !project.servers.contains(where: { existing in
                existing.alias.compare(candidate, options: [.caseInsensitive]) == .orderedSame
            }) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Backup helpers

    private func createBackup(for storeURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: storeURL.path])
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let baseName = storeURL.deletingPathExtension().lastPathComponent
        let backupName = "\(baseName)-backup-\(stamp).sqlite"
        let backupURL = storeURL.deletingLastPathComponent().appendingPathComponent(backupName)
        try fileManager.copyItem(at: storeURL, to: backupURL)

        var urls = [backupURL]
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        if fileManager.fileExists(atPath: walURL.path) {
            let walBackup = URL(fileURLWithPath: backupURL.path + "-wal")
            try? fileManager.copyItem(at: walURL, to: walBackup)
            urls.append(walBackup)
        }
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        if fileManager.fileExists(atPath: shmURL.path) {
            let shmBackup = URL(fileURLWithPath: backupURL.path + "-shm")
            try? fileManager.copyItem(at: shmURL, to: shmBackup)
            urls.append(shmBackup)
        }

        return urls
    }

    private func deleteBackup(_ urls: [URL]) {
        let fileManager = FileManager.default
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }
}
