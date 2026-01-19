//
//  SkillRecordSyncService.swift
//  MCP Bundler
//
//  Synchronizes SwiftData SkillRecord rows with the on-disk global skills library.
//

import Foundation
import os.log
import SwiftData

@MainActor
struct SkillRecordSyncService {
    private let log = Logger(subsystem: "mcp-bundler", category: "skills.records")
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func synchronizeRecords(with infos: [SkillInfo], in context: ModelContext) throws -> [Project] {
        let descriptor = FetchDescriptor<SkillRecord>(sortBy: [SortDescriptor(\SkillRecord.slug, order: .forward)])
        let existing = try context.fetch(descriptor)

        var recordBySkillId: [String: SkillRecord] = [:]
        var recordBySourcePath: [String: SkillRecord] = [:]
        var recordBySlug: [String: SkillRecord] = [:]
        var skillIdCounts: [String: Int] = [:]
        for record in existing {
            skillIdCounts[record.skillId, default: 0] += 1
        }
        var loggedDuplicateSkillIds = Set<String>()
        for record in existing {
            if skillIdCounts[record.skillId] == 1 {
                recordBySkillId[record.skillId] = record
            } else if loggedDuplicateSkillIds.insert(record.skillId).inserted {
                log.error("Duplicate SkillRecord skillId '\(record.skillId, privacy: .public)' detected; disabling id-based matching until repaired")
            }
            recordBySourcePath[standardPath(record.sourcePath)] = record
            if recordBySlug[record.slug] == nil {
                recordBySlug[record.slug] = record
            } else {
                log.error("Duplicate SkillRecord rows for slug '\(record.slug, privacy: .public)' detected; using first match for synchronization")
            }
        }

        let selectionDescriptor = FetchDescriptor<ProjectSkillSelection>(predicate: #Predicate { $0.enabled })
        let enabledSelections = try context.fetch(selectionDescriptor)

        var enabledProjectsBySlug: [String: [Project]] = [:]
        for selection in enabledSelections {
            guard let project = selection.project else { continue }
            enabledProjectsBySlug[selection.skillSlug, default: []].append(project)
        }

        let discovered = try resolveDiscoveredSkills(from: infos, recordBySourcePath: recordBySourcePath)
        let discoveredIds = Set(discovered.map(\.skillId))

        var impactedProjects: [Project] = []

        for info in discovered {
            let resolvedSourcePath = standardPath(info.source.path(percentEncoded: false))
            let record = recordBySkillId[info.skillId] ?? recordBySourcePath[resolvedSourcePath] ?? recordBySlug[info.slug]

            if let record {
                if record.skillId != info.skillId {
                    log.info("Updating skillId for \(record.slug, privacy: .public) to match manifest \(info.skillId, privacy: .public)")
                    record.skillId = info.skillId
                    record.markUpdated()
                    recordBySkillId[info.skillId] = record
                }

                let slugBefore = record.slug
                var didUpdate = false
                if record.slug != info.slug {
                    try applySlugRename(from: slugBefore, to: info.slug, in: context)
                    record.slug = info.slug
                    didUpdate = true
                    if let projects = enabledProjectsBySlug[slugBefore] {
                        impactedProjects.append(contentsOf: projects)
                    }
                }

                if record.name != info.name {
                    record.name = info.name
                    didUpdate = true
                }
                if record.descriptionText != info.description {
                    record.descriptionText = info.description
                    didUpdate = true
                }

                let path = standardPath(info.source.path(percentEncoded: false))
                if standardPath(record.sourcePath) != path {
                    record.sourcePath = info.source.path(percentEncoded: false)
                    didUpdate = true
                }
                if record.isArchive != info.isArchive {
                    record.isArchive = info.isArchive
                    didUpdate = true
                }

                if didUpdate {
                    record.markUpdated()
                    if let projects = enabledProjectsBySlug[record.slug] {
                        impactedProjects.append(contentsOf: projects)
                    }
                }
            } else {
                let record = SkillRecord(skillId: info.skillId,
                                         slug: info.slug,
                                         name: info.name,
                                         descriptionText: info.description,
                                         exposeViaMcp: false,
                                         sourcePath: info.source.path(percentEncoded: false),
                                         isArchive: info.isArchive)
                context.insert(record)
            }
        }

        for record in existing where !discoveredIds.contains(record.skillId) {
            if let projects = enabledProjectsBySlug[record.slug] {
                impactedProjects.append(contentsOf: projects)
            }
            try removeSelections(for: record.slug, in: context)
            context.delete(record)
        }

        if context.hasChanges {
            try context.save()
        }

        return uniquedProjects(impactedProjects)
    }

    // MARK: - Discovery

    private struct DiscoveredSkill: Hashable {
        let skillId: String
        let slug: String
        let name: String
        let description: String
        let source: URL
        let isArchive: Bool
    }

    private func resolveDiscoveredSkills(from infos: [SkillInfo],
                                         recordBySourcePath: [String: SkillRecord]) throws -> [DiscoveredSkill] {
        var results: [DiscoveredSkill] = []

        for info in infos {
            let source = info.source
            let sourcePath = standardPath(source.path(percentEncoded: false))
            let skillId = try resolveSkillId(for: info, recordBySourcePath: recordBySourcePath, sourcePath: sourcePath)
            results.append(DiscoveredSkill(skillId: skillId,
                                           slug: info.slug,
                                           name: info.name,
                                           description: info.description,
                                           source: source,
                                           isArchive: info.isArchive))
        }

        return try repairDuplicateSkillIds(in: results, recordBySourcePath: recordBySourcePath)
    }

    private func resolveSkillId(for info: SkillInfo,
                                recordBySourcePath: [String: SkillRecord],
                                sourcePath: String) throws -> String {
        if !info.isArchive {
            if let manifest = try SkillSyncManifestIO.load(from: info.source, fileManager: fileManager),
               manifest.managedBy == SkillSyncManifest.managedByValue {
                return manifest.skillId
            }

            let skillId = recordBySourcePath[sourcePath]?.skillId ?? UUID().uuidString
            try seedCanonicalManifest(skillId: skillId, directory: info.source)
            return skillId
        }

        if let record = recordBySourcePath[sourcePath] {
            return record.skillId
        }

        return UUID().uuidString
    }

    private func repairDuplicateSkillIds(in discovered: [DiscoveredSkill],
                                         recordBySourcePath: [String: SkillRecord]) throws -> [DiscoveredSkill] {
        var indicesBySkillId: [String: [Int]] = [:]
        indicesBySkillId.reserveCapacity(discovered.count)
        for (index, skill) in discovered.enumerated() {
            indicesBySkillId[skill.skillId, default: []].append(index)
        }

        let duplicates = indicesBySkillId.filter { $0.value.count > 1 }
        guard !duplicates.isEmpty else {
            return discovered
        }

        var usedSkillIds = Set(discovered.map(\.skillId))
        func makeUniqueSkillId() -> String {
            var value = UUID().uuidString
            while usedSkillIds.contains(value) {
                value = UUID().uuidString
            }
            usedSkillIds.insert(value)
            return value
        }

        var updated = discovered

        for (duplicateSkillId, indices) in duplicates {
            let ordered = indices.sorted { lhs, rhs in
                let lhsPath = standardPath(updated[lhs].source.path(percentEncoded: false))
                let rhsPath = standardPath(updated[rhs].source.path(percentEncoded: false))
                let lhsHasExisting = recordBySourcePath[lhsPath] != nil
                let rhsHasExisting = recordBySourcePath[rhsPath] != nil
                if lhsHasExisting != rhsHasExisting {
                    return lhsHasExisting
                }
                return updated[lhs].slug.localizedCaseInsensitiveCompare(updated[rhs].slug) == .orderedAscending
            }

            guard let keeperIndex = ordered.first else { continue }
            log.error("Duplicate skillId '\(duplicateSkillId, privacy: .public)' detected across \(indices.count, privacy: .public) skills; reassigning IDs")
            for index in ordered where index != keeperIndex {
                let newSkillId = makeUniqueSkillId()
                try seedCanonicalManifest(skillId: newSkillId, directory: updated[index].source)
                updated[index] = DiscoveredSkill(skillId: newSkillId,
                                                 slug: updated[index].slug,
                                                 name: updated[index].name,
                                                 description: updated[index].description,
                                                 source: updated[index].source,
                                                 isArchive: updated[index].isArchive)
            }
        }

        return updated
    }

    private func seedCanonicalManifest(skillId: String, directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return }

        if let existing = try SkillSyncManifestIO.load(from: directory, fileManager: fileManager),
           existing.managedBy == SkillSyncManifest.managedByValue,
           existing.skillId == skillId,
           existing.lastSyncedHash != nil {
            return
        }

        let hash = try SkillDigest.sha256Hex(forSkillDirectory: directory, fileManager: fileManager)
        let manifest = SkillSyncManifest(skillId: skillId,
                                         canonical: true,
                                         tool: SkillSyncManifest.canonicalTool,
                                         lastSyncAt: Date(),
                                         lastSyncedHash: hash)
        try SkillSyncManifestIO.save(manifest, to: directory, fileManager: fileManager)
    }

    // MARK: - Selections

    private func applySlugRename(from oldSlug: String, to newSlug: String, in context: ModelContext) throws {
        guard oldSlug != newSlug else { return }
        let descriptor = FetchDescriptor<ProjectSkillSelection>()
        let matches = try context.fetch(descriptor).filter { $0.skillSlug == oldSlug }
        for selection in matches {
            selection.skillSlug = newSlug
            selection.updatedAt = Date()
        }
    }

    private func removeSelections(for slug: String, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<ProjectSkillSelection>()
        let matches = try context.fetch(descriptor).filter { $0.skillSlug == slug }
        for selection in matches {
            context.delete(selection)
        }
    }

    private func uniquedProjects(_ projects: [Project]) -> [Project] {
        var seen: Set<PersistentIdentifier> = []
        var result: [Project] = []
        for project in projects {
            let id = project.persistentModelID
            if seen.insert(id).inserted {
                result.append(project)
            }
        }
        return result
    }

    private func standardPath(_ raw: String) -> String {
        URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}
