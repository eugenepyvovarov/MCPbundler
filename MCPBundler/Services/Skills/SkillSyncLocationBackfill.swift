//
//  SkillSyncLocationBackfill.swift
//  MCP Bundler
//
//  Migrates legacy Codex/Claude skill sync settings into multi-location data models.
//

import Foundation
import SwiftData

enum SkillSyncLocationBackfill {
    private static let backfillKey = "SkillSyncLocation.Backfill.v1"

    static func perform(in container: ModelContainer, userDefaults: UserDefaults = .standard) {
        let context = container.mainContext

        do {
            let locations = try context.fetch(FetchDescriptor<SkillSyncLocation>())
            normalizeBuiltInDisplayNames(locations)
            if userDefaults.bool(forKey: backfillKey) {
                if context.hasChanges {
                    try context.save()
                }
                return
            }

            let codexLocation = ensureBuiltInLocation(key: SkillSyncLocationTemplates.codexKey,
                                                      existing: locations,
                                                      in: context)
            let claudeLocation = ensureBuiltInLocation(key: SkillSyncLocationTemplates.claudeKey,
                                                       existing: locations,
                                                       in: context)

            applyLegacyPreferences(codex: codexLocation, claude: claudeLocation, userDefaults: userDefaults)
            try migrateLegacyEnablements(in: context,
                                         codexLocation: codexLocation,
                                         claudeLocation: claudeLocation)

            if context.hasChanges {
                try context.save()
            }

            userDefaults.set(true, forKey: backfillKey)
        } catch {
            AppDelegate.writeToStderr("mcp-bundler: skills location backfill failed: \(error)\n")
        }
    }

    private static func normalizeBuiltInDisplayNames(_ locations: [SkillSyncLocation]) {
        for location in locations where location.kind == .builtIn {
            let key = location.templateKey ?? location.locationId
            guard let template = SkillSyncLocationTemplates.template(for: key) else { continue }
            location.updateDisplayName(template.displayName)
        }
    }

    private static func ensureBuiltInLocation(key: String,
                                              existing: [SkillSyncLocation],
                                              in context: ModelContext) -> SkillSyncLocation? {
        if let match = existing.first(where: { $0.locationId == key || $0.templateKey == key }) {
            return match
        }

        guard let template = SkillSyncLocationTemplates.template(for: key) else { return nil }

        let root = template.expandedRootURL().path
        let disabled = template.expandedDisabledURL().path
        let location = SkillSyncLocation(locationId: template.key,
                                         displayName: template.displayName,
                                         rootPath: root,
                                         disabledRootPath: disabled,
                                         isManaged: false,
                                         pinRank: nil,
                                         templateKey: template.key,
                                         kind: .builtIn)
        context.insert(location)
        return location
    }

    private static func applyLegacyPreferences(codex: SkillSyncLocation?,
                                               claude: SkillSyncLocation?,
                                               userDefaults: UserDefaults) {
        let codexEnabled = userDefaults.bool(forKey: NativeSkillsSyncPreferences.syncCodexEnabledKey)
        let claudeEnabled = userDefaults.bool(forKey: NativeSkillsSyncPreferences.syncClaudeEnabledKey)

        var desiredPins: [SkillSyncLocation] = []
        if codexEnabled, let codex { desiredPins.append(codex) }
        if claudeEnabled, let claude { desiredPins.append(claude) }

        for location in desiredPins {
            if !location.isManaged {
                location.setManaged(true)
            }
        }

        for (index, location) in desiredPins.enumerated() {
            guard location.pinRank == nil else { continue }
            location.setPinRank(index)
        }
    }

    private static func migrateLegacyEnablements(in context: ModelContext,
                                                 codexLocation: SkillSyncLocation?,
                                                 claudeLocation: SkillSyncLocation?) throws {
        let records = try context.fetch(FetchDescriptor<SkillRecord>())
        let enablements = try context.fetch(FetchDescriptor<SkillLocationEnablement>())
        var enablementByKey: [String: SkillLocationEnablement] = [:]

        for enablement in enablements {
            guard let skill = enablement.skill, let location = enablement.location else { continue }
            let key = "\(skill.skillId)::\(location.locationId)"
            enablementByKey[key] = enablement
        }

        if let codexLocation {
            for record in records where record.enabledInCodex {
                ensureEnablement(skill: record,
                                 location: codexLocation,
                                 enablementByKey: &enablementByKey,
                                 in: context)
            }
        }

        if let claudeLocation {
            for record in records where record.enabledInClaude {
                ensureEnablement(skill: record,
                                 location: claudeLocation,
                                 enablementByKey: &enablementByKey,
                                 in: context)
            }
        }
    }

    private static func ensureEnablement(skill: SkillRecord,
                                         location: SkillSyncLocation,
                                         enablementByKey: inout [String: SkillLocationEnablement],
                                         in context: ModelContext) {
        let key = "\(skill.skillId)::\(location.locationId)"
        if let existing = enablementByKey[key] {
            existing.setEnabled(true)
            return
        }

        let enablement = SkillLocationEnablement(skill: skill, location: location, enabled: true)
        enablementByKey[key] = enablement
        context.insert(enablement)
    }
}
