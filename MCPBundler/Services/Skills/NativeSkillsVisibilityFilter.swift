//
//  NativeSkillsVisibilityFilter.swift
//  MCP Bundler
//
//  Applies per-client filtering so native-skills clients don't see duplicate MCP skill tools/resources.
//

import Foundation

nonisolated enum NativeSkillsVisibilityFilter {
    static func filterTools(_ tools: [NamespacedTool], hiddenSkillSlugs: Set<String>) -> [NamespacedTool] {
        var filtered = tools

        if !hiddenSkillSlugs.isEmpty {
            filtered = tools.filter { tool in
                guard tool.alias == SkillsCapabilitiesBuilder.alias else { return true }
                if tool.original == SkillsCapabilitiesBuilder.compatibilityToolName {
                    return true
                }
                return !hiddenSkillSlugs.contains(tool.original)
            }
        }

        let hasAnySkillTool = filtered.contains { tool in
            tool.alias == SkillsCapabilitiesBuilder.alias &&
                tool.original != SkillsCapabilitiesBuilder.compatibilityToolName
        }

        if !hasAnySkillTool {
            filtered.removeAll { tool in
                tool.alias == SkillsCapabilitiesBuilder.alias &&
                    tool.original == SkillsCapabilitiesBuilder.compatibilityToolName
            }
        }

        return filtered
    }

    static func filterResources(_ resources: [NamespacedResource], hiddenSkillSlugs: Set<String>) -> [NamespacedResource] {
        guard !hiddenSkillSlugs.isEmpty else { return resources }
        return resources.filter { resource in
            guard resource.alias == SkillsCapabilitiesBuilder.alias else { return true }
            guard let slug = skillSlug(fromSkillsResourceOriginalURI: resource.originalURI) else { return true }
            return !hiddenSkillSlugs.contains(slug)
        }
    }

    static func shouldHideSkillsTool(originalToolName: String, hiddenSkillSlugs: Set<String>) -> Bool {
        guard !hiddenSkillSlugs.isEmpty else { return false }
        guard originalToolName != SkillsCapabilitiesBuilder.compatibilityToolName else { return false }
        return hiddenSkillSlugs.contains(originalToolName)
    }

    static func shouldHideSkillsResource(originalURI: String, hiddenSkillSlugs: Set<String>) -> Bool {
        guard !hiddenSkillSlugs.isEmpty else { return false }
        guard let slug = skillSlug(fromSkillsResourceOriginalURI: originalURI) else { return false }
        return hiddenSkillSlugs.contains(slug)
    }

    static func skillSlug(fromSkillsResourceOriginalURI uri: String) -> String? {
        guard let url = URL(string: uri),
              url.scheme == "mcpbundler-skill",
              let slugHost = url.host else {
            return nil
        }
        return slugHost.removingPercentEncoding ?? slugHost
    }
}

