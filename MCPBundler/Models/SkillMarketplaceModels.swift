//
//  SkillMarketplaceModels.swift
//  MCP Bundler
//
//  Data models for marketplace sources and marketplace JSON payloads.
//

import Foundation
import SwiftData

@Model
final class SkillMarketplaceSource {
    var sourceId: String
    var owner: String
    var repo: String
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    var cachedManifestSHA: String?
    var cachedDefaultBranch: String?
    var cachedMarketplaceJSON: String?
    var cachedSkillNamesJSON: String?
    var cacheUpdatedAt: Date?

    init(sourceId: String = UUID().uuidString,
         owner: String,
         repo: String,
         displayName: String,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.sourceId = sourceId
        self.owner = owner
        self.repo = repo
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cachedManifestSHA = nil
        self.cachedDefaultBranch = nil
        self.cachedMarketplaceJSON = nil
        self.cachedSkillNamesJSON = nil
        self.cacheUpdatedAt = nil
    }

    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }
        displayName = trimmed
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }

    var normalizedKey: String {
        "\(owner)/\(repo)".lowercased()
    }

    func cachedSkillNames() -> [String]? {
        guard let cachedSkillNamesJSON,
              let data = cachedSkillNamesJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    func updateMarketplaceCache(manifestSHA: String?,
                                defaultBranch: String,
                                manifestJSON: String,
                                skillNames: [String]) {
        cachedManifestSHA = manifestSHA
        cachedDefaultBranch = defaultBranch
        cachedMarketplaceJSON = manifestJSON
        cacheUpdatedAt = Date()

        if let data = try? JSONEncoder().encode(skillNames),
           let text = String(data: data, encoding: .utf8) {
            cachedSkillNamesJSON = text
        } else {
            cachedSkillNamesJSON = nil
        }
    }

    func clearMarketplaceCache() {
        cachedManifestSHA = nil
        cachedDefaultBranch = nil
        cachedMarketplaceJSON = nil
        cachedSkillNamesJSON = nil
        cacheUpdatedAt = nil
    }
}

struct SkillMarketplaceDocument: Codable, Hashable, Sendable {
    let name: String
    let owner: SkillMarketplaceOwner
    let metadata: SkillMarketplaceMetadata?
    let plugins: [SkillMarketplacePlugin]
}

struct SkillMarketplaceOwner: Codable, Hashable, Sendable {
    let name: String
    let email: String?
}

struct SkillMarketplaceMetadata: Codable, Hashable, Sendable {
    let description: String?
    let version: String?
    let pluginRoot: String?
}

struct SkillMarketplaceAuthor: Codable, Hashable, Sendable {
    let name: String
}

struct SkillMarketplacePlugin: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let source: SkillMarketplacePluginSource
    let description: String?
    let category: String?
    let author: SkillMarketplaceAuthor?
    let keywords: [String]?

    var id: String { name }
}

enum SkillMarketplacePluginSource: Codable, Hashable, Sendable {
    case path(String)
    case github(repo: String, ref: String?, path: String?)
    case url(String)
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case source
        case repo
        case url
        case ref
        case path
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            self = .path(value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(String.self, forKey: .source)
        switch source {
        case "github":
            let repo = try container.decode(String.self, forKey: .repo)
            let ref = try container.decodeIfPresent(String.self, forKey: .ref)
            let path = try container.decodeIfPresent(String.self, forKey: .path)
            self = .github(repo: repo, ref: ref, path: path)
        case "url":
            let url = try container.decode(String.self, forKey: .url)
            self = .url(url)
        default:
            self = .unknown(source)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .path(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .github(let repo, let ref, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("github", forKey: .source)
            try container.encode(repo, forKey: .repo)
            try container.encodeIfPresent(ref, forKey: .ref)
            try container.encodeIfPresent(path, forKey: .path)
        case .url(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("url", forKey: .source)
            try container.encode(value, forKey: .url)
        case .unknown(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .source)
        }
    }
}
