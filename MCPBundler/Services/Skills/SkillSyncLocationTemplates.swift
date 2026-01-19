//
//  SkillSyncLocationTemplates.swift
//  MCP Bundler
//
//  Built-in templates for managed native skills locations.
//

import Foundation

struct SkillSyncLocationTemplate: Identifiable, Hashable {
    let key: String
    let displayName: String
    let rootPath: String
    let disabledRootPath: String

    var id: String { key }

    func expandedRootURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        URL(fileURLWithPath: SkillSyncLocationTemplates.expandPath(rootPath, home: home))
    }

    func expandedDisabledURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        URL(fileURLWithPath: SkillSyncLocationTemplates.expandPath(disabledRootPath, home: home))
    }
}

enum SkillSyncLocationTemplates {
    static let codexKey = "codex"
    static let claudeKey = "claude"
    static let vscodeKey = "vscode"
    static let ampKey = "amp"
    static let opencodeHomeKey = "opencode-home"
    static let opencodeConfigKey = "opencode-config"
    static let gooseKey = "goose"

    static let all: [SkillSyncLocationTemplate] = [
        SkillSyncLocationTemplate(key: codexKey,
                                  displayName: "Codex",
                                  rootPath: "~/.codex/skills",
                                  disabledRootPath: "~/.codex/skills.disabled"),
        SkillSyncLocationTemplate(key: claudeKey,
                                  displayName: "Claude Code",
                                  rootPath: "~/.claude/skills",
                                  disabledRootPath: "~/.claude/skills.disabled"),
        SkillSyncLocationTemplate(key: vscodeKey,
                                  displayName: "VS Code",
                                  rootPath: "~/.github/skills",
                                  disabledRootPath: "~/.github/skills.disabled"),
        SkillSyncLocationTemplate(key: ampKey,
                                  displayName: "Amp",
                                  rootPath: "~/.config/amp/skills",
                                  disabledRootPath: "~/.config/amp/skills.disabled"),
        SkillSyncLocationTemplate(key: opencodeHomeKey,
                                  displayName: "OpenCode (home)",
                                  rootPath: "~/.opencode/skills",
                                  disabledRootPath: "~/.opencode/skills.disabled"),
        SkillSyncLocationTemplate(key: opencodeConfigKey,
                                  displayName: "OpenCode (config)",
                                  rootPath: "~/.config/opencode/skills",
                                  disabledRootPath: "~/.config/opencode/skills.disabled"),
        SkillSyncLocationTemplate(key: gooseKey,
                                  displayName: "Goose",
                                  rootPath: "~/.config/goose/skills",
                                  disabledRootPath: "~/.config/goose/skills.disabled")
    ]

    static func template(for key: String) -> SkillSyncLocationTemplate? {
        all.first { $0.key == key }
    }

    static func expandPath(_ rawPath: String, home: URL) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        if trimmed == "~" {
            return home.path
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return home.appendingPathComponent(suffix, isDirectory: true).path
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func defaultDisabledPath(for rootURL: URL) -> URL {
        let parent = rootURL.deletingLastPathComponent()
        let base = rootURL.lastPathComponent + ".disabled"
        return parent.appendingPathComponent(base, isDirectory: true)
    }
}
