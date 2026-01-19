//
//  ServerURLNormalizer.swift
//  MCP Bundler
//
//  Shared helpers for normalizing server base URLs.
//

import Foundation

enum ServerURLNormalizer {
    static func normalize(_ raw: String) -> String {
        normalizeOptional(raw) ?? ""
    }

    static func normalizeOptional(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadTrailingSlash = trimmed.hasSuffix("/") && !trimmed.hasSuffix("://")

        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.path = components.path.isEmpty ? "/" : components.path
        if hadTrailingSlash,
           components.path.count > 1,
           !components.path.hasSuffix("/") {
            components.path += "/"
        }
        if let port = components.port {
            let scheme = components.scheme?.lowercased()
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                components.port = nil
            }
        }
        return components.string ?? trimmed
    }
}
