//
//  SkillMarketplaceSourceDefaults.swift
//  MCP Bundler
//
//  Default marketplace sources and ordering rules.
//

import Foundation

struct SkillMarketplaceDefaultSource: Hashable {
    let owner: String
    let repo: String
    let displayName: String
    let sortRank: Int

    var normalizedKey: String {
        "\(owner)/\(repo)".lowercased()
    }
}

enum SkillMarketplaceSourceDefaults {
    static let sources: [SkillMarketplaceDefaultSource] = [
        SkillMarketplaceDefaultSource(owner: "eugenepyvovarov",
                                      repo: "mcpbundler-agent-skills-marketplace",
                                      displayName: "MCPBundler Currated Marketplace",
                                      sortRank: 0),
        SkillMarketplaceDefaultSource(owner: "ComposioHQ",
                                      repo: "awesome-claude-skills",
                                      displayName: "awesome-claude-skills",
                                      sortRank: 1)
    ]

    private static let sortOrder: [String: Int] = {
        var order: [String: Int] = [:]
        for source in sources {
            order[source.normalizedKey] = source.sortRank
        }
        return order
    }()

    static func sortRank(for normalizedKey: String) -> Int? {
        sortOrder[normalizedKey]
    }

    static func sortSources(_ sources: [SkillMarketplaceSource]) -> [SkillMarketplaceSource] {
        sources.sorted { lhs, rhs in
            let lhsRank = sortOrder[lhs.normalizedKey] ?? Int.max
            let rhsRank = sortOrder[rhs.normalizedKey] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            let ownerOrder = lhs.owner.localizedCaseInsensitiveCompare(rhs.owner)
            if ownerOrder != .orderedSame {
                return ownerOrder == .orderedAscending
            }
            return lhs.repo.localizedCaseInsensitiveCompare(rhs.repo) == .orderedAscending
        }
    }
}
