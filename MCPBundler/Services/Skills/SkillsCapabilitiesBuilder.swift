//
//  SkillsCapabilitiesBuilder.swift
//  MCP Bundler
//
//  Maps selected skills into MCPCapabilities under the skills alias.
//

import Foundation
import MCP
import os.log
import SwiftData

struct SkillsCapabilitiesBuilder {
    nonisolated static let alias = "mcpbundler_skills"
    nonisolated static let compatibilityToolName = "fetch_resource"

    private static let log = Logger(subsystem: "mcp-bundler", category: "skills.capabilities")

    private static let toolInputSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "task": .object([
                "type": .string("string")
            ])
        ]),
        "required": .array([.string("task")]),
        "additionalProperties": .bool(false)
    ])

    private static let fetchResourceSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "resource_uri": .object([
                "type": .string("string")
            ])
        ]),
        "required": .array([.string("resource_uri")]),
        "additionalProperties": .bool(false)
    ])

    @MainActor
    static func capabilities(for project: Project,
                             library: SkillsLibraryService,
                             in context: ModelContext) async -> MCPCapabilities {
        do {
            let skillDescriptor = FetchDescriptor<SkillRecord>(sortBy: [SortDescriptor(\SkillRecord.slug, order: .forward)])
            let skillRecords = try context.fetch(skillDescriptor)
            guard !skillRecords.isEmpty else {
                return baseCapabilities(tools: [], resources: nil)
            }

            let selectionDescriptor = FetchDescriptor<ProjectSkillSelection>()
            let projectID = project.persistentModelID
            let selections = try context.fetch(selectionDescriptor).filter { selection in
                selection.enabled && selection.project?.persistentModelID == projectID
            }
            let enabledSlugs = Set(selections.map { $0.skillSlug })
            guard !enabledSlugs.isEmpty else {
                return baseCapabilities(tools: [], resources: nil)
            }

            let discoveredSkills = await library.list()
            var infoBySlug: [String: SkillInfo] = [:]
            for info in discoveredSkills {
                if infoBySlug[info.slug] == nil {
                    infoBySlug[info.slug] = info
                } else {
                    log.error("Duplicate discovered skill slug '\(info.slug, privacy: .public)' while building capabilities; ignoring later entry")
                }
            }

            var tools: [MCPTool] = []
            var resources: [MCPResource] = []

            for record in skillRecords {
                guard enabledSlugs.contains(record.slug) else { continue }
                guard let info = infoBySlug[record.slug] else {
                    log.warning("Selected skill '\(record.slug, privacy: .public)' missing from library index; skipping exposure")
                    continue
                }

                let displayName = normalized(record.displayNameOverride) ?? record.name
                let description = normalized(record.descriptionOverride) ?? info.description

                let tool = MCPTool(
                    name: record.slug,
                    title: displayName,
                    description: description,
                    inputSchema: toolInputSchema
                )
                tools.append(tool)

                for resource in info.resources {
                    let resourceName = "\(record.slug)/\(resource.relativePath)"
                    let resourceURI = Self.makeSkillURI(slug: record.slug, relativePath: resource.relativePath)
                    resources.append(MCPResource(name: resourceName,
                                                 uri: resourceURI,
                                                 description: nil))
                }
            }

            guard !tools.isEmpty else {
                return baseCapabilities(tools: [], resources: nil)
            }

            tools.append(fetchResourceTool())

            let resourceList = resources.isEmpty ? nil : resources.sorted { $0.name < $1.name }
            return baseCapabilities(tools: tools.sorted { $0.name < $1.name }, resources: resourceList)
        } catch {
            log.error("Failed to build skills capabilities: \(error.localizedDescription, privacy: .public)")
            return baseCapabilities(tools: [], resources: nil)
        }
    }

    private static func baseCapabilities(tools: [MCPTool], resources: [MCPResource]?) -> MCPCapabilities {
        MCPCapabilities(serverName: "Skills",
                        serverDescription: "Virtual tools exposed from the MCP Bundler skills library.",
                        tools: tools,
                        resources: resources,
                        prompts: nil)
    }

    private static func fetchResourceTool() -> MCPTool {
        MCPTool(name: compatibilityToolName,
                title: "Fetch Skill Resource",
                description: "Compatibility helper for clients without resources/read. Call fetch_resource with the bundled resource URI to fetch skill files.",
                inputSchema: fetchResourceSchema)
    }

    private static func makeSkillURI(slug: String, relativePath: String) -> String {
        let encodedSlug = encodeSlug(slug)
        let encodedPath = relativePath
            .split(separator: "/")
            .map { encodePathComponent(String($0)) }
            .joined(separator: "/")
        return "mcpbundler-skill://\(encodedSlug)/\(encodedPath)"
    }

    private static func encodeSlug(_ value: String) -> String {
        var allowed = CharacterSet.urlHostAllowed
        allowed.remove(charactersIn: "%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodePathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
