//
//  SkillSyncManifest.swift
//  MCP Bundler
//
//  Managed marker for skills synchronized between MCP Bundler and native clients.
//

import Foundation

nonisolated struct SkillSyncManifest: Codable, Hashable {
    static let currentVersion = 1
    static let managedByValue = "mcp-bundler"
    static let canonicalTool = "bundler"

    let version: Int
    var skillId: String
    var managedBy: String
    var canonical: Bool
    var lastSyncAt: Date?
    var lastSyncedHash: String?
    var tool: String

    init(skillId: String,
         canonical: Bool,
         tool: String,
         lastSyncAt: Date? = nil,
         lastSyncedHash: String? = nil,
         version: Int = SkillSyncManifest.currentVersion,
         managedBy: String = SkillSyncManifest.managedByValue) {
        self.version = version
        self.skillId = skillId
        self.managedBy = managedBy
        self.canonical = canonical
        self.lastSyncAt = lastSyncAt
        self.lastSyncedHash = lastSyncedHash
        self.tool = tool
    }
}

nonisolated enum SkillSyncManifestIO {
    static let directoryName = ".mcp-bundler"
    static let fileName = "manifest.json"

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
        }
        return decoder
    }

    static func manifestURL(for skillDirectory: URL) -> URL {
        skillDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(from skillDirectory: URL, fileManager: FileManager = .default) throws -> SkillSyncManifest? {
        let url = manifestURL(for: skillDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(SkillSyncManifest.self, from: data)
    }

    static func save(_ manifest: SkillSyncManifest, to skillDirectory: URL, fileManager: FileManager = .default) throws {
        let directoryURL = skillDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let url = manifestURL(for: skillDirectory)
        let data = try makeEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }
}
