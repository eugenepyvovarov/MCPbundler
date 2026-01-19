//
//  OAuthDebugLogger.swift
//  MCP Bundler
//
//  Centralized helper for emitting optional OAuth debug logs.
//

import Foundation
import SwiftData

enum OAuthDebugLogger {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func log(_ message: String,
                    category: String,
                    server: Server,
                    metadata: [String: String]? = nil) {
        guard server.isOAuthDebugLoggingEnabled else { return }
        guard let project = server.project, let context = project.modelContext else { return }

        var payload = metadata ?? [:]
        let trimmedAlias = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAlias.isEmpty {
            payload["alias"] = trimmedAlias
            payload["alias_normalized"] = normalizedAlias(for: trimmedAlias)
        }

        let metadataData = payload.isEmpty ? nil : try? encoder.encode(payload)

        let entry = LogEntry(project: project,
                             timestamp: Date(),
                             level: .debug,
                             category: category,
                             message: message,
                             metadata: metadataData)
        context.insert(entry)
        try? context.save()
    }

    private static func normalizedAlias(for alias: String) -> String {
        alias.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
    }
}

extension OAuthDebugLogger {
    static func summarizeToken(_ token: String?) -> String {
        guard let token, !token.isEmpty else { return "(empty)" }
        let prefix = token.prefix(6)
        let suffix = token.suffix(4)
        return "len=\(token.count) prefix=\(prefix)… suffix=\(suffix)"
    }
}
