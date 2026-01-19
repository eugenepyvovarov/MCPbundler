//
//  SkillSyncLocationModels.swift
//  MCP Bundler
//
//  Data models for skills sync locations and per-skill enablement.
//

import Foundation
import SwiftData

enum SkillSyncLocationKind: String, Codable, CaseIterable, Identifiable {
    case builtIn
    case custom

    var id: String { rawValue }
}

@Model
final class SkillSyncLocation {
    var locationId: String
    var displayName: String
    var rootPath: String
    var disabledRootPath: String
    var isManaged: Bool
    var pinRank: Int?
    var createdAt: Date
    var updatedAt: Date
    var templateKey: String?
    var kind: SkillSyncLocationKind

    @Relationship(deleteRule: .cascade, inverse: \SkillLocationEnablement.location)
    var enablements: [SkillLocationEnablement]

    init(locationId: String,
         displayName: String,
         rootPath: String,
         disabledRootPath: String,
         isManaged: Bool = false,
         pinRank: Int? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         templateKey: String? = nil,
         kind: SkillSyncLocationKind) {
        self.locationId = locationId
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.disabledRootPath = disabledRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isManaged = isManaged
        self.pinRank = pinRank
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.templateKey = templateKey
        self.kind = kind
        self.enablements = []
    }

    var isPinned: Bool {
        pinRank != nil
    }

    func setManaged(_ newValue: Bool) {
        guard isManaged != newValue else { return }
        isManaged = newValue
        markUpdated()
    }

    func setPinRank(_ newValue: Int?) {
        guard pinRank != newValue else { return }
        pinRank = newValue
        markUpdated()
    }

    func updateDisplayName(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayName != trimmed else { return }
        displayName = trimmed
        markUpdated()
    }

    func updatePaths(rootPath: String, disabledRootPath: String) {
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisabled = disabledRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.rootPath != trimmedRoot || self.disabledRootPath != trimmedDisabled else { return }
        self.rootPath = trimmedRoot
        self.disabledRootPath = trimmedDisabled
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }
}

@Model
final class SkillLocationEnablement {
    @Relationship var skill: SkillRecord?
    @Relationship var location: SkillSyncLocation?
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(skill: SkillRecord? = nil,
         location: SkillSyncLocation? = nil,
         enabled: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.skill = skill
        self.location = location
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func setEnabled(_ newValue: Bool) {
        guard enabled != newValue else { return }
        enabled = newValue
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }
}
