import Foundation
import MCP
import SwiftData
import os.log

@MainActor
enum ProjectSnapshotCache {
    private static let skillsLog = Logger(subsystem: "mcp-bundler", category: "skills.snapshot")
    private static let integrityLog = Logger(subsystem: "mcp-bundler", category: "integrity.snapshot")

    struct Payload: Codable {
        let version: Int
        let generatedAt: Date
        private let storedSnapshot: StoredSnapshot

        var snapshot: BundlerAggregator.Snapshot {
            storedSnapshot.toSnapshot()
        }

        init(version: Int, generatedAt: Date, snapshot: BundlerAggregator.Snapshot) {
            self.version = version
            self.generatedAt = generatedAt
            self.storedSnapshot = StoredSnapshot(from: snapshot)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            generatedAt = try container.decode(Date.self, forKey: .generatedAt)
            storedSnapshot = try container.decode(StoredSnapshot.self, forKey: .storedSnapshot)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(generatedAt, forKey: .generatedAt)
            try container.encode(storedSnapshot, forKey: .storedSnapshot)
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case generatedAt
            case storedSnapshot
        }
    }

    static let currentVersion: Int = 1

    enum CacheError: Error {
        case snapshotUnavailable
    }

    private struct CachedSnapshot {
        let version: Int
        let generatedAt: Date
        let snapshot: BundlerAggregator.Snapshot
    }

    private static var snapshotCache: [PersistentIdentifier: CachedSnapshot] = [:]

    static func rebuildSnapshot(for project: Project) async throws {
        let snapshot = try await makeSnapshot(for: project)
        try store(snapshot: snapshot, for: project)
        project.snapshotRevision &+= 1
        if let context = project.modelContext {
            let service = BundlerEventService(context: context)
            service.enqueue(for: project, type: .snapshotRebuilt)
        }
    }

    static func ensureSnapshot(for project: Project) async {
        guard needsRebuild(project: project) else { return }
        do {
            try await rebuildSnapshot(for: project)
        } catch {
            let message = "mcp-bundler: Failed to rebuild cached snapshot for project \(project.name): \(error.localizedDescription)\n"
            if let data = message.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }

    static func ensureSnapshots(in container: ModelContainer) async {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Project>()
        let projects = (try? context.fetch(descriptor)) ?? []
        for project in projects {
            await ensureSnapshot(for: project)
        }
        if context.hasChanges {
            try? context.save()
        }
    }

    static func needsRebuild(project: Project) -> Bool {
        guard let cachedAt = project.cachedSnapshotGeneratedAt,
              let data = project.cachedSnapshot,
              let version = project.cachedSnapshotVersion,
              version == currentVersion,
              cachedAt >= project.updatedAt else {
            clearCache(for: project)
            return true
        }
        if data.isEmpty {
            clearCache(for: project)
            return true
        }
        return false
    }

    static func decodeSnapshot(from data: Data) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Payload.self, from: data)
    }

    private static func store(snapshot: BundlerAggregator.Snapshot, for project: Project) throws {
        let payload = Payload(version: currentVersion, generatedAt: Date(), snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        project.cachedSnapshot = data
        project.cachedSnapshotVersion = currentVersion
        project.cachedSnapshotGeneratedAt = payload.generatedAt

        if let key = cacheKey(for: project) {
            snapshotCache[key] = CachedSnapshot(version: payload.version,
                                                generatedAt: payload.generatedAt,
                                                snapshot: snapshot)
        }
    }

    private static func makeSnapshot(for project: Project) async throws -> BundlerAggregator.Snapshot {
        let capabilityInputs = try await prepareCapabilities(for: project)
        let aggregator = BundlerAggregator(serverCapabilities: capabilityInputs)
        return try await aggregator.buildSnapshot()
    }

    private static func prepareCapabilities(for project: Project) async throws -> [(server: Server, capabilities: MCPCapabilities)] {
        var results: [(Server, MCPCapabilities)] = []
        for server in project.servers where server.isEffectivelyEnabled {
            guard let capabilities = server.latestDecodedCapabilities else { continue }
            results.append((server, capabilities))
        }

        guard let context = project.modelContext else {
            return results
        }

        let library = SkillsLibraryService()
        do {
            try await library.reload()
            let skillsCapabilities = await SkillsCapabilitiesBuilder.capabilities(for: project, library: library, in: context)
            let hasTools = !skillsCapabilities.tools.isEmpty
            let hasResources = skillsCapabilities.resources?.isEmpty == false
            if hasTools || hasResources {
                let skillsServer = Server(project: nil, alias: SkillsCapabilitiesBuilder.alias, kind: .local_stdio)
                skillsServer.isEnabled = true
                results.append((skillsServer, skillsCapabilities))
            }
        } catch {
            skillsLog.error("Failed to load skills capabilities for snapshot: \(error.localizedDescription, privacy: .public)")
        }

        return results
    }

    static func snapshot(for project: Project) throws -> BundlerAggregator.Snapshot {
        guard let data = project.cachedSnapshot,
              let version = project.cachedSnapshotVersion,
              let generatedAt = project.cachedSnapshotGeneratedAt else {
            throw CacheError.snapshotUnavailable
        }

        if let key = cacheKey(for: project),
           let cached = snapshotCache[key],
           cached.version == version,
           cached.generatedAt == generatedAt {
            return cached.snapshot
        }

        let payload = try decodeSnapshot(from: data)
        if let key = cacheKey(for: project) {
            snapshotCache[key] = CachedSnapshot(version: payload.version,
                                                generatedAt: payload.generatedAt,
                                                snapshot: payload.snapshot)
        }
        return payload.snapshot
    }

    static func clearCache(for project: Project) {
        if let key = cacheKey(for: project) {
            snapshotCache.removeValue(forKey: key)
        }
        project.snapshotRevision = 0
    }

    private static func cacheKey(for project: Project) -> PersistentIdentifier? {
        project.persistentModelID
    }

    private struct StoredSnapshot: Codable {
        let tools: [StoredTool]
        let prompts: [StoredPrompt]
        let resources: [StoredResource]

        init(from snapshot: BundlerAggregator.Snapshot) {
            self.tools = snapshot.tools.map(StoredTool.init)
            self.prompts = snapshot.prompts.map(StoredPrompt.init)
            self.resources = snapshot.resources.map(StoredResource.init)
        }

        func toSnapshot() -> BundlerAggregator.Snapshot {
            func logDuplicate(kind: String, alias: String, key: String) {
                ProjectSnapshotCache.integrityLog.warning("""
                Duplicate \(kind, privacy: .public) '\(key, privacy: .public)' \
                for alias '\(alias, privacy: .public)'; keeping last entry.
                """)
            }

            func dedupe<T>(items: [T],
                           key: (T) -> String,
                           alias: (T) -> String,
                           kind: String,
                           sort: (T, T) -> Bool) -> [T] {
                var map: [String: T] = [:]
                for item in items {
                    let resolvedKey = key(item)
                    if map[resolvedKey] != nil {
                        logDuplicate(kind: kind, alias: alias(item), key: resolvedKey)
                    }
                    map[resolvedKey] = item
                }
                return map.values.sorted(by: sort)
            }

            func buildMap<T, Value>(items: [T],
                                    key: (T) -> String,
                                    value: (T) -> Value,
                                    alias: (T) -> String,
                                    kind: String) -> [String: Value] {
                var map: [String: Value] = [:]
                for item in items {
                    let resolvedKey = key(item)
                    if map[resolvedKey] != nil {
                        logDuplicate(kind: kind, alias: alias(item), key: resolvedKey)
                    }
                    map[resolvedKey] = value(item)
                }
                return map
            }

            let toolModels = dedupe(items: tools.map { $0.toModel() },
                                    key: { $0.namespaced },
                                    alias: { $0.alias },
                                    kind: "tool",
                                    sort: { $0.namespaced < $1.namespaced })
            let promptModels = dedupe(items: prompts.map { $0.toModel() },
                                      key: { $0.namespaced },
                                      alias: { $0.alias },
                                      kind: "prompt",
                                      sort: { $0.namespaced < $1.namespaced })
            let resourceModels = dedupe(items: resources.map { $0.toModel() },
                                        key: { $0.name },
                                        alias: { $0.alias },
                                        kind: "resource",
                                        sort: { $0.name < $1.name })

            let toolMap = buildMap(items: toolModels,
                                   key: { $0.namespaced },
                                   value: { ($0.alias, $0.original) },
                                   alias: { $0.alias },
                                   kind: "tool")
            let promptMap = buildMap(items: promptModels,
                                     key: { $0.namespaced },
                                     value: { ($0.alias, $0.original) },
                                     alias: { $0.alias },
                                     kind: "prompt")
            let resourceMap = buildMap(items: resourceModels,
                                       key: { $0.uri },
                                       value: { ($0.alias, $0.originalURI) },
                                       alias: { $0.alias },
                                       kind: "resource-uri")

            return BundlerAggregator.Snapshot(tools: toolModels,
                                              prompts: promptModels,
                                              resources: resourceModels,
                                              toolMap: toolMap,
                                              promptMap: promptMap,
                                              resourceMap: resourceMap)
        }
    }

    private struct StoredTool: Codable {
        let namespaced: String
        let alias: String
        let original: String
        let title: String?
        let description: String?
        let inputSchemaJSON: String?
        let annotations: Tool.Annotations?

        init(from tool: NamespacedTool) {
            self.namespaced = tool.namespaced
            self.alias = tool.alias
            self.original = tool.original
            self.title = tool.title
            self.description = tool.description
            self.inputSchemaJSON = Self.encodeValue(tool.inputSchema)
            self.annotations = tool.annotations
        }

        func toModel() -> NamespacedTool {
            NamespacedTool(namespaced: namespaced,
                           alias: alias,
                           original: original,
                           title: title,
                           description: description,
                           inputSchema: Self.decodeValue(inputSchemaJSON),
                           annotations: annotations)
        }

        private static func encodeValue(_ value: Value?) -> String? {
            guard let value else { return nil }
            let json = value.toStandardJSON()
            guard JSONSerialization.isValidJSONObject(json) else { return nil }
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func decodeValue(_ jsonString: String?) -> Value? {
            guard let jsonString, let data = jsonString.data(using: .utf8) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return Value.fromStandardJSON(json)
        }
    }

    private struct StoredPrompt: Codable {
        let namespaced: String
        let alias: String
        let original: String
        let description: String?

        init(from prompt: NamespacedPrompt) {
            self.namespaced = prompt.namespaced
            self.alias = prompt.alias
            self.original = prompt.original
            self.description = prompt.description
        }

        func toModel() -> NamespacedPrompt {
            NamespacedPrompt(namespaced: namespaced,
                             alias: alias,
                             original: original,
                             description: description)
        }
    }

    private struct StoredResource: Codable {
        let name: String
        let uri: String
        let alias: String
        let originalURI: String
        let description: String?

        init(from resource: NamespacedResource) {
            self.name = resource.name
            self.uri = resource.uri
            self.alias = resource.alias
            self.originalURI = resource.originalURI
            self.description = resource.description
        }

        func toModel() -> NamespacedResource {
            NamespacedResource(name: name,
                               uri: uri,
                               alias: alias,
                               originalURI: originalURI,
                               description: description)
        }
    }
}
