//
//  SkillsModels.swift
//  MCP Bundler
//
//  Data models for global skill records and per-project selections.
//

import Foundation
import SwiftData

@Model
final class SkillFolder {
    var name: String
    var isCollapsed: Bool
    var createdAt: Date
    var updatedAt: Date

    @Relationship(inverse: \SkillRecord.folder) var skills: [SkillRecord]

    init(name: String, isCollapsed: Bool = false) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isCollapsed = isCollapsed
        self.createdAt = Date()
        self.updatedAt = Date()
        self.skills = []
    }

    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != name else { return }
        name = trimmed
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }
}

extension SkillFolder {
    var stableID: PersistentIdentifier { persistentModelID }
}

@Model
final class SkillRecord {
    var skillId: String = UUID().uuidString
    var slug: String
    var name: String
    var descriptionText: String
    var displayNameOverride: String?
    var descriptionOverride: String?
    var enabledInCodex: Bool = false
    var enabledInClaude: Bool = false
    var exposeViaMcp: Bool = false
    var sourcePath: String
    var isArchive: Bool
    @Relationship(deleteRule: .nullify) var folder: SkillFolder?
    @Relationship(deleteRule: .cascade, inverse: \SkillLocationEnablement.skill)
    var locationEnablements: [SkillLocationEnablement]
    var createdAt: Date
    var updatedAt: Date

    init(skillId: String = UUID().uuidString,
         slug: String,
         name: String,
         descriptionText: String,
         enabledInCodex: Bool = false,
         enabledInClaude: Bool = false,
         exposeViaMcp: Bool = false,
         sourcePath: String,
         isArchive: Bool,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.skillId = skillId
        self.slug = slug
        self.name = name
        self.descriptionText = descriptionText
        self.displayNameOverride = nil
        self.descriptionOverride = nil
        self.enabledInCodex = enabledInCodex
        self.enabledInClaude = enabledInClaude
        self.exposeViaMcp = exposeViaMcp
        self.sourcePath = sourcePath
        self.isArchive = isArchive
        self.folder = nil
        self.locationEnablements = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func setEnabledInCodex(_ newValue: Bool) {
        guard enabledInCodex != newValue else { return }
        enabledInCodex = newValue
        markUpdated()
    }

    func setEnabledInClaude(_ newValue: Bool) {
        guard enabledInClaude != newValue else { return }
        enabledInClaude = newValue
        markUpdated()
    }

    func setExposeViaMcp(_ newValue: Bool) {
        guard exposeViaMcp != newValue else { return }
        exposeViaMcp = newValue
        markUpdated()
    }

    func applyDisplayNameOverride(_ value: String?) {
        guard displayNameOverride != value else { return }
        displayNameOverride = value
        markUpdated()
    }

    func applyDescriptionOverride(_ value: String?) {
        guard descriptionOverride != value else { return }
        descriptionOverride = value
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }
}

@Model
final class ProjectSkillSelection {
    @Relationship var project: Project?
    var skillSlug: String
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(project: Project? = nil,
         skillSlug: String,
         enabled: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.project = project
        self.skillSlug = skillSlug
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
