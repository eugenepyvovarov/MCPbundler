//
//  BundlerAggregator.swift
//  MCP Bundler
//
//  Aggregates capabilities from multiple upstream MCP servers
//  and provides namespacing with optional include filtering.
//

import Foundation
import MCP
import os.log

// MARK: - DTOs used by the bundler core

struct NamespacedTool: Sendable {
    let namespaced: String // alias__tool
    let alias: String
    let original: String
    let title: String?
    let description: String?
    let inputSchema: Value?
    let annotations: Tool.Annotations?
}

struct NamespacedPrompt: Sendable {
    let namespaced: String // alias__prompt
    let alias: String
    let original: String
    let description: String?
}

struct NamespacedResource: Sendable {
    let name: String // display name (alias__original)
    let uri: String  // bundler URI, e.g. mcp-bundler://alias/<base64 of original>
    let alias: String
    let originalURI: String
    let description: String?
}

enum BundlerURI {
    nonisolated static let scheme = "mcp-bundler"

    nonisolated static func wrap(alias: String, originalURI: String) -> String {
        let data = originalURI.data(using: .utf8) ?? Data()
        let encoded = data.base64EncodedString()
        return "\(scheme)://\(alias)/\(encoded)"
    }

    nonisolated static func unwrap(_ bundledURI: String) -> (alias: String, originalURI: String)? {
        guard bundledURI.hasPrefix("\(scheme)://") else { return nil }
        let rest = bundledURI.dropFirst((scheme + "://").count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let alias = String(rest[..<slash])
        let b64 = String(rest[rest.index(after: slash)...])
        guard let data = Data(base64Encoded: b64), let orig = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (alias, orig)
    }
}

// MARK: - Aggregator

actor BundlerAggregator {
    private static let integrityLog = Logger(subsystem: "mcp-bundler", category: "integrity.snapshot")

    struct Snapshot: Sendable {
        let tools: [NamespacedTool]
        let prompts: [NamespacedPrompt]
        let resources: [NamespacedResource]
        // reverse lookup maps
        let toolMap: [String: (alias: String, original: String)] // namespaced -> (alias, original)
        let promptMap: [String: (alias: String, original: String)]
        let resourceMap: [String: (alias: String, originalURI: String)] // bundledURI -> (alias, originalURI)
    }

    private let inputs: [(server: Server, capabilities: MCPCapabilities)]

    init(serverCapabilities: [(server: Server, capabilities: MCPCapabilities)]) {
        self.inputs = serverCapabilities
    }

    // Build a fresh snapshot by querying upstream capabilities using providers (already configured with env/headers).
    func buildSnapshot() async throws -> Snapshot {
        var tools: [NamespacedTool] = []
        var prompts: [NamespacedPrompt] = []
        var resources: [NamespacedResource] = []

        for (server, caps) in inputs {
            guard !caps.tools.isEmpty || (caps.prompts?.isEmpty == false) || (caps.resources?.isEmpty == false) else {
                continue
            }

            // Tools
            for t in caps.tools {
                guard shouldInclude(name: t.name, include: server.includeTools) else { continue }
                let ns = namespacedToolName(alias: server.alias, toolName: t.name)
                let annotations = t.annotations ?? t.title.map { Tool.Annotations(title: $0) }

                tools.append(NamespacedTool(namespaced: ns,
                                           alias: server.alias,
                                           original: t.name,
                                           title: t.title ?? annotations?.title,
                                           description: t.description,
                                           inputSchema: t.inputSchema,
                                           annotations: annotations))
            }

            // Prompts
            if let pr = caps.prompts {
                for p in pr {
                    let ns = namespaced(server.alias, p.name)
                    prompts.append(NamespacedPrompt(namespaced: ns, alias: server.alias, original: p.name, description: p.description))
                }
            }

            // Resources
            if let rr = caps.resources {
                for r in rr {
                    let nsName = namespaced(server.alias, r.name)
                    let wrapped = BundlerURI.wrap(alias: server.alias, originalURI: r.uri)
                    resources.append(NamespacedResource(name: nsName, uri: wrapped, alias: server.alias, originalURI: r.uri, description: r.description))
                }
            }
        }

        let dedupedTools = dedupe(items: tools,
                                  key: { $0.namespaced },
                                  alias: { $0.alias },
                                  kind: "tool",
                                  sort: { $0.namespaced < $1.namespaced })
        let dedupedPrompts = dedupe(items: prompts,
                                    key: { $0.namespaced },
                                    alias: { $0.alias },
                                    kind: "prompt",
                                    sort: { $0.namespaced < $1.namespaced })
        let dedupedResources = dedupe(items: resources,
                                      key: { $0.name },
                                      alias: { $0.alias },
                                      kind: "resource",
                                      sort: { $0.name < $1.name })

        let toolMap = buildMap(items: dedupedTools,
                               key: { $0.namespaced },
                               value: { ($0.alias, $0.original) },
                               alias: { $0.alias },
                               kind: "tool")
        let promptMap = buildMap(items: dedupedPrompts,
                                 key: { $0.namespaced },
                                 value: { ($0.alias, $0.original) },
                                 alias: { $0.alias },
                                 kind: "prompt")
        let resourceMap = buildMap(items: dedupedResources,
                                   key: { $0.uri },
                                   value: { ($0.alias, $0.originalURI) },
                                   alias: { $0.alias },
                                   kind: "resource-uri")

        return Snapshot(tools: dedupedTools,
                        prompts: dedupedPrompts,
                        resources: dedupedResources,
                        toolMap: toolMap,
                        promptMap: promptMap,
                        resourceMap: resourceMap)
    }

    // Helpers
    private func namespaced(_ alias: String, _ name: String) -> String { "\(alias)__\(name)" }

    private func namespacedToolName(alias: String, toolName: String) -> String {
        if alias == SkillsCapabilitiesBuilder.alias &&
            toolName == SkillsCapabilitiesBuilder.compatibilityToolName {
            return toolName
        }
        return namespaced(alias, toolName)
    }

    private func shouldInclude(name: String, include: [String]) -> Bool {
        include.isEmpty || include.contains(name)
    }

    private func dedupe<T>(items: [T],
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

    private func buildMap<T, Value>(items: [T],
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

    private func logDuplicate(kind: String, alias: String, key: String) {
        Self.integrityLog.warning("""
        Duplicate \(kind, privacy: .public) '\(key, privacy: .public)' \
        for alias '\(alias, privacy: .public)'; keeping last entry.
        """)
    }

    // Helper to describe MCP Value for debugging
    private func describeValue(_ value: Value) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return "bool(\(b))"
        case .int(let i):
            return "int(\(i))"
        case .double(let d):
            return "double(\(d))"
        case .string(let s):
            return "string(\(s))"
        case .array(let a):
            return "array(\(a.count) items)"
        case .object(let o):
            let props = o.keys.sorted().joined(separator: ", ")
            return "object { \(props) }"
        case .data(mimeType: _, _):
            return "data(...)"
        }
    }
}
