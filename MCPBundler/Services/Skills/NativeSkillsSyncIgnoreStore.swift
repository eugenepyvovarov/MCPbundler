//
//  NativeSkillsSyncIgnoreStore.swift
//  MCP Bundler
//
//  Persists ignore rules for unmanaged native skills discovered in managed locations.
//

import Foundation

nonisolated struct NativeSkillsSyncIgnoreRule: Codable, Hashable {
    let tool: String
    let directoryPath: String
    let lastSeenHash: String?
    let updatedAt: Date

    init(tool: String, directoryPath: String, lastSeenHash: String?, updatedAt: Date = Date()) {
        self.tool = tool
        self.directoryPath = directoryPath
        self.lastSeenHash = lastSeenHash
        self.updatedAt = updatedAt
    }
}

nonisolated struct NativeSkillsSyncIgnoreStore {
    private static let storageKey = "NativeSkillsSync.UnmanagedIgnoreRules.v1"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> [NativeSkillsSyncIgnoreRule] {
        guard let data = userDefaults.data(forKey: Self.storageKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NativeSkillsSyncIgnoreRule].self, from: data)) ?? []
    }

    func save(_ rules: [NativeSkillsSyncIgnoreRule]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rules) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    func isIgnored(tool: String, directoryPath: String, currentHash: String?) -> Bool {
        let rules = load()
        guard let match = rules.first(where: { $0.tool == tool && $0.directoryPath == directoryPath }) else {
            return false
        }
        guard let expectedHash = match.lastSeenHash else {
            return true
        }
        return expectedHash == currentHash
    }

    func addIgnore(tool: String, directoryPath: String, currentHash: String?) {
        var rules = load()
        let rule = NativeSkillsSyncIgnoreRule(tool: tool, directoryPath: directoryPath, lastSeenHash: currentHash)
        rules.removeAll { $0.tool == tool && $0.directoryPath == directoryPath }
        rules.append(rule)
        save(rules)
    }

    func removeIgnore(tool: String, directoryPath: String) {
        var rules = load()
        rules.removeAll { $0.tool == tool && $0.directoryPath == directoryPath }
        save(rules)
    }
}
