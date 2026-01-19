//
//  NativeSkillsSyncService.swift
//  MCP Bundler
//
//  Synchronizes MCP Bundler's canonical skills library with managed native skills folders.
//

import Foundation
import Combine
import os.log

nonisolated struct SkillFrontMatterSummary: Hashable, Sendable {
    let name: String
    let description: String
}

nonisolated enum SkillFrontMatterReader {
    static func read(from url: URL, fileManager: FileManager = .default) throws -> SkillFrontMatterSummary {
        let data = try Data(contentsOf: url)
        return try parse(data: data, sourcePath: url.path(percentEncoded: false))
    }

    static func parse(data: Data, sourcePath: String) throws -> SkillFrontMatterSummary {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw SkillsLibraryError.invalidSkill("SKILL.md at \(sourcePath) is not valid UTF-8/UTF-16 text")
        }

        let (frontMatterLines, _) = try splitFrontMatterAndBody(from: text)
        let parsed = try parseFrontMatter(lines: frontMatterLines, sourcePath: sourcePath)
        return SkillFrontMatterSummary(name: parsed.name, description: parsed.description)
    }

    private static func splitFrontMatterAndBody(from text: String) throws -> ([String], String) {
        let sanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = sanitized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            throw SkillsLibraryError.invalidSkill("SKILL.md missing YAML front matter opening delimiter '---'")
        }
        lines.removeFirst()
        var frontMatter: [String] = []
        while !lines.isEmpty {
            let line = lines.removeFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            frontMatter.append(line)
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")
        return (frontMatter, body)
    }

    private struct FrontMatter {
        var name: String
        var description: String
    }

    private static func parseFrontMatter(lines: [String], sourcePath: String) throws -> FrontMatter {
        var name: String?
        var description: String?
        var currentBlockKey: String?
        var currentBlockIndent: Int = 0
        var blockBuffer: [String] = []

        func flushBlock() {
            guard let key = currentBlockKey else { return }
            let joined = blockBuffer.joined(separator: "\n")
            assignValue(joined, to: key)
            currentBlockKey = nil
            blockBuffer = []
        }

        func assignValue(_ value: String, to key: String) {
            switch key {
            case "name":
                name = value
            case "description":
                description = value
            default:
                break
            }
        }

        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")

            if currentBlockKey != nil {
                let indent = indentationLevel(of: line)
                if indent >= currentBlockIndent && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let stripped = String(line.dropFirst(currentBlockIndent))
                    blockBuffer.append(stripped)
                    continue
                } else {
                    flushBlock()
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            if trimmed.hasPrefix("#") {
                continue
            }

            if let colonIndex = line.firstIndex(of: ":") {
                flushBlock()

                let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

                if value == "|" || value == "|-" || value == ">" || value == ">-" {
                    currentBlockKey = key
                    currentBlockIndent = indentationLevel(of: line) + 2
                    blockBuffer = []
                    continue
                }

                if value.isEmpty {
                    continue
                }

                assignValue(value, to: key)
            }
        }

        flushBlock()

        guard let resolvedName = name, !resolvedName.isEmpty else {
            throw SkillsLibraryError.invalidSkill("Front matter missing 'name' at \(sourcePath)")
        }

        guard let resolvedDescription = description, !resolvedDescription.isEmpty else {
            throw SkillsLibraryError.invalidSkill("Front matter missing 'description' at \(sourcePath)")
        }

        return FrontMatter(name: resolvedName, description: resolvedDescription)
    }

    private static func indentationLevel(of line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " {
                count += 1
            } else if char == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }
}

nonisolated enum NativeSkillsSyncPreferences {
    static let syncCodexEnabledKey = "NativeSkillsSync.SyncCodexEnabled.v1"
    static let syncClaudeEnabledKey = "NativeSkillsSync.SyncClaudeEnabled.v1"

    static func isCodexSyncEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: syncCodexEnabledKey)
    }

    static func isClaudeSyncEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: syncClaudeEnabledKey)
    }
}

nonisolated struct SkillSyncLocationDescriptor: Hashable, Sendable {
    let locationId: String
    let displayName: String
    let rootURL: URL
    let disabledRootURL: URL

    init(locationId: String, displayName: String, rootPath: String, disabledRootPath: String) {
        self.locationId = locationId
        self.displayName = displayName
        self.rootURL = URL(fileURLWithPath: rootPath)
        self.disabledRootURL = URL(fileURLWithPath: disabledRootPath)
    }
}

nonisolated struct NativeSkillsSyncState: Hashable, Sendable {
    let locationId: String
    let displayName: String
    let directoryPath: String
    let currentHash: String
    let changedFromBaseline: Bool
}

nonisolated struct NativeSkillsSyncConflict: Identifiable, Hashable, Sendable {
    var id: String { skillId }

    let skillId: String
    let slug: String
    let baselineHash: String
    let enabledLocationIds: Set<String>
    let states: [NativeSkillsSyncState]
}

nonisolated private struct SkillExportSnapshot: Sendable {
    let skillId: String
    let slug: String
    let sourcePath: String
    let isArchive: Bool

    init(skill: SkillRecord) {
        self.skillId = skill.skillId
        self.slug = skill.slug
        self.sourcePath = skill.sourcePath
        self.isArchive = skill.isArchive
    }

    var canonicalURL: URL {
        URL(fileURLWithPath: sourcePath)
    }
}

nonisolated private struct SkillSyncSnapshot: Sendable {
    let skillId: String
    let slug: String
    let sourcePath: String
    let enabledLocationIds: Set<String>

    init(skill: SkillRecord, enabledLocationIds: Set<String>) {
        self.skillId = skill.skillId
        self.slug = skill.slug
        self.sourcePath = skill.sourcePath
        self.enabledLocationIds = enabledLocationIds
    }

    var canonicalURL: URL {
        URL(fileURLWithPath: sourcePath)
    }
}

@MainActor
final class NativeSkillsSyncService: ObservableObject {
    struct UnmanagedSkillCandidate: Identifiable, Hashable {
        enum Source: Hashable {
            case directory(URL)
            case rootFile(URL)

            var skillFile: URL {
                switch self {
                case .directory(let directory):
                    return directory.appendingPathComponent("SKILL.md", isDirectory: false)
                case .rootFile(let file):
                    return file
                }
            }

            var pathKey: String {
                switch self {
                case .directory(let directory):
                    return directory.standardizedFileURL.path
                case .rootFile(let file):
                    return file.standardizedFileURL.path
                }
            }

            var displayPath: String {
                switch self {
                case .directory(let directory):
                    return directory.path(percentEncoded: false)
                case .rootFile(let file):
                    return file.path(percentEncoded: false)
                }
            }
        }

        var id: String { "\(locationId)::\(source.pathKey)" }

        let locationId: String
        let locationName: String
        let source: Source
        let contentHash: String?
        let skillName: String?
        let skillDescription: String?
        let parseError: String?

        var directory: URL? {
            if case .directory(let directory) = source {
                return directory
            }
            return nil
        }

        var skillFile: URL { source.skillFile }
        var pathKey: String { source.pathKey }
        var displayPath: String { source.displayPath }
    }

    @Published private(set) var unmanagedCandidates: [UnmanagedSkillCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastScanError: String?
    @Published private(set) var lastExportError: String?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var conflicts: [NativeSkillsSyncConflict] = []

    private let fileManager: FileManager
    private let ignoreStore: NativeSkillsSyncIgnoreStore
    private let log = Logger(subsystem: "mcp-bundler", category: "skills.sync")

    init(fileManager: FileManager = .default,
         ignoreStore: NativeSkillsSyncIgnoreStore? = nil) {
        self.fileManager = fileManager
        self.ignoreStore = ignoreStore ?? NativeSkillsSyncIgnoreStore()
    }

    func scanUnmanaged(locations: [SkillSyncLocationDescriptor]) async {
        isScanning = true
        lastScanError = nil
        defer { isScanning = false }

        do {
            let engine = NativeSkillsSyncEngine(fileManager: fileManager)
            var candidates: [NativeSkillsSyncService.UnmanagedSkillCandidate] = []
            for location in locations {
                candidates.append(contentsOf: try engine.scanUnmanagedSkills(in: location))
            }

            unmanagedCandidates = candidates
                .compactMap { candidate -> UnmanagedSkillCandidate? in
                    let hash: String?
                    switch candidate.source {
                    case .directory(let directory):
                        hash = try? SkillDigest.sha256Hex(forSkillDirectory: directory, fileManager: fileManager)
                    case .rootFile(let file):
                        hash = try? SkillDigest.sha256Hex(forFile: file, fileManager: fileManager)
                    }

                    if ignoreStore.isIgnored(tool: candidate.locationId,
                                            directoryPath: candidate.pathKey,
                                            currentHash: hash) {
                        return nil
                    }

                    let summary: SkillFrontMatterSummary?
                    let parseError: String?
                    do {
                        summary = try SkillFrontMatterReader.read(from: candidate.skillFile, fileManager: fileManager)
                        parseError = nil
                    } catch {
                        summary = nil
                        parseError = error.localizedDescription
                    }
                    return UnmanagedSkillCandidate(locationId: candidate.locationId,
                                                   locationName: candidate.locationName,
                                                   source: candidate.source,
                                                   contentHash: hash,
                                                   skillName: summary?.name,
                                                   skillDescription: summary?.description,
                                                   parseError: parseError)
                }
                .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
        } catch {
            lastScanError = error.localizedDescription
            log.error("Failed unmanaged scan: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applyExport(for skill: SkillRecord, location: SkillSyncLocationDescriptor, enabled: Bool) async {
        lastExportError = nil

        let snapshot = SkillExportSnapshot(skill: skill)
        do {
            try await applyExport(snapshot: snapshot, location: location, enabled: enabled)
        } catch {
            lastExportError = error.localizedDescription
            log.error("Native export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeExports(for skill: SkillRecord, locations: [SkillSyncLocationDescriptor]) async throws {
        guard !locations.isEmpty else { return }
        lastExportError = nil

        let snapshot = SkillExportSnapshot(skill: skill)
        let fileManager = fileManager

        do {
            try await Task.detached(priority: .utility) {
                let engine = NativeSkillsSyncEngine(fileManager: fileManager)
                for location in locations {
                    try engine.removeSkillExports(skillId: snapshot.skillId, in: location)
                }
            }.value
        } catch {
            lastExportError = error.localizedDescription
            log.error("Native export cleanup failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func ignore(_ candidate: UnmanagedSkillCandidate) {
        ignoreStore.addIgnore(tool: candidate.locationId,
                              directoryPath: candidate.pathKey,
                              currentHash: candidate.contentHash)
        unmanagedCandidates.removeAll { $0.id == candidate.id }
    }

    func syncManaged(skills: [SkillRecord],
                     enablementsBySkillId: [String: Set<String>],
                     locations: [SkillSyncLocationDescriptor]) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        conflicts = []
        defer { isSyncing = false }

        let snapshots = skills.map { skill in
            SkillSyncSnapshot(skill: skill, enabledLocationIds: enablementsBySkillId[skill.skillId] ?? [])
        }
        let fileManager = fileManager

        do {
            let results = try await Task.detached(priority: .utility) {
                let engine = NativeSkillsSyncEngine(fileManager: fileManager)
                var conflicts: [NativeSkillsSyncConflict] = []
                for snapshot in snapshots {
                    let outcome = try engine.syncSkill(skillId: snapshot.skillId,
                                                       preferredSlug: snapshot.slug,
                                                       canonicalDirectory: snapshot.canonicalURL,
                                                       enabledLocationIds: snapshot.enabledLocationIds,
                                                       locations: locations,
                                                       forceSource: nil)
                    if case .conflict(let conflict) = outcome {
                        conflicts.append(conflict)
                    }
                }
                return conflicts
            }.value

            conflicts = results.sorted { lhs, rhs in
                lhs.slug.localizedCaseInsensitiveCompare(rhs.slug) == .orderedAscending
            }
        } catch {
            lastSyncError = error.localizedDescription
            log.error("Native skills sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resolve(conflict: NativeSkillsSyncConflict,
                 keeping locationId: String,
                 locations: [SkillSyncLocationDescriptor]) async {
        lastSyncError = nil
        let fileManager = fileManager

        do {
            try await Task.detached(priority: .utility) {
                guard let canonical = conflict.states.first(where: { $0.locationId == SkillSyncManifest.canonicalTool }) else {
                    return
                }
                let engine = NativeSkillsSyncEngine(fileManager: fileManager)
                _ = try engine.syncSkill(skillId: conflict.skillId,
                                         preferredSlug: conflict.slug,
                                         canonicalDirectory: URL(fileURLWithPath: canonical.directoryPath),
                                         enabledLocationIds: conflict.enabledLocationIds,
                                         locations: locations,
                                         forceSource: locationId)
            }.value

            conflicts.removeAll { $0.skillId == conflict.skillId }
        } catch {
            lastSyncError = error.localizedDescription
            log.error("Conflict resolution failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyExport(snapshot: SkillExportSnapshot,
                             location: SkillSyncLocationDescriptor,
                             enabled: Bool) async throws {
        let fileManager = fileManager
        try await Task.detached {
            let engine = NativeSkillsSyncEngine(fileManager: fileManager)
            if enabled {
                try engine.ensureCanonicalManifest(skillId: snapshot.skillId, canonicalDirectory: snapshot.canonicalURL)
                try engine.exportSkillDirectory(from: snapshot.canonicalURL,
                                                preferredSlug: snapshot.slug,
                                                skillId: snapshot.skillId,
                                                to: location)
            } else {
                try engine.disableSkillExport(skillId: snapshot.skillId, preferredSlug: snapshot.slug, in: location)
            }
        }.value
    }
}

// MARK: - Engine

nonisolated struct NativeSkillsSyncEngine {
    enum SyncOutcome: Hashable, Sendable {
        case upToDate
        case exportsCreated([String])
        case propagated(source: String)
        case conflict(NativeSkillsSyncConflict)
    }

    enum EngineError: LocalizedError {
        case archiveSkillsRequireMaterialization
        case unmanagedDestination(URL)
        case invalidCanonicalSkill(String)
        case missingManagedExport(String)

        var errorDescription: String? {
            switch self {
            case .archiveSkillsRequireMaterialization:
                return "Archive skills must be materialized to a directory before native export."
            case .unmanagedDestination(let url):
                return "Destination is not managed by MCP Bundler: \(url.path(percentEncoded: false))"
            case .invalidCanonicalSkill(let message):
                return "Canonical skill is invalid: \(message)"
            case .missingManagedExport(let locationId):
                return "Managed export missing in \(locationId)."
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scanUnmanagedSkills(in location: SkillSyncLocationDescriptor) throws -> [NativeSkillsSyncService.UnmanagedSkillCandidate] {
        let root = location.rootURL
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        var candidates: [NativeSkillsSyncService.UnmanagedSkillCandidate] = []
        var seenSources = Set<String>()

        let enumerator = fileManager.enumerator(at: root,
                                                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                options: [.skipsHiddenFiles],
                                                errorHandler: { _, _ in true })

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator?.skipDescendants()
                }
                continue
            }

            if values.isDirectory == true {
                continue
            }

            guard item.lastPathComponent == "SKILL.md" else { continue }
            let directory = item.deletingLastPathComponent()
            let standardizedDir = directory.standardizedFileURL.path

            if standardizedDir == root.standardizedFileURL.path {
                let key = item.standardizedFileURL.path
                guard seenSources.insert(key).inserted else { continue }
                candidates.append(.init(locationId: location.locationId,
                                        locationName: location.displayName,
                                        source: .rootFile(item),
                                        contentHash: nil,
                                        skillName: nil,
                                        skillDescription: nil,
                                        parseError: nil))
                continue
            }

            let key = standardizedDir
            guard seenSources.insert(key).inserted else { continue }

            if try SkillSyncManifestIO.load(from: directory, fileManager: fileManager) != nil {
                continue
            }

            candidates.append(.init(locationId: location.locationId,
                                    locationName: location.displayName,
                                    source: .directory(directory),
                                    contentHash: nil,
                                    skillName: nil,
                                    skillDescription: nil,
                                    parseError: nil))
        }

        return candidates
    }

    func ensureDirectoryExists(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func disableSkillExport(skillId: String,
                            preferredSlug: String? = nil,
                            in location: SkillSyncLocationDescriptor) throws {
        let activeRoot = location.rootURL
        let disabledRoot = location.disabledRootURL

        let activeDir = try findManagedSkillDirectory(skillId: skillId, in: activeRoot) ??
            preferredSlug.map { activeRoot.appendingPathComponent($0, isDirectory: true) }

        guard let activeDir, fileManager.fileExists(atPath: activeDir.path) else { return }
        guard try isManagedDirectory(activeDir, skillId: skillId) else { return }

        try ensureDirectoryExists(disabledRoot)
        if activeRoot.standardizedFileURL.path != disabledRoot.standardizedFileURL.path {
            let disabledMatches = try findManagedSkillDirectories(skillId: skillId, in: disabledRoot)
            for directory in disabledMatches {
                try fileManager.removeItem(at: directory)
            }
        }
        let destination = uniqueDestination(for: activeDir.lastPathComponent, in: disabledRoot)
        try fileManager.moveItem(at: activeDir, to: destination)
    }

    func removeSkillExports(skillId: String,
                            in location: SkillSyncLocationDescriptor) throws {
        let activeMatches = try findManagedSkillDirectories(skillId: skillId, in: location.rootURL)
        let disabledMatches = try findManagedSkillDirectories(skillId: skillId, in: location.disabledRootURL)
        let matches = Array(Set(activeMatches + disabledMatches))
        for directory in matches {
            try fileManager.removeItem(at: directory)
        }
    }

    func exportSkillDirectory(from canonicalDirectory: URL,
                              preferredSlug: String,
                              skillId: String,
                              to location: SkillSyncLocationDescriptor) throws {
        guard fileManager.fileExists(atPath: canonicalDirectory.path) else {
            throw EngineError.invalidCanonicalSkill("Missing canonical directory: \(canonicalDirectory.path(percentEncoded: false))")
        }
        guard canonicalDirectory.hasDirectoryPath else {
            throw EngineError.archiveSkillsRequireMaterialization
        }

        let activeRoot = location.rootURL
        let disabledRoot = location.disabledRootURL
        try ensureDirectoryExists(activeRoot)

        let destination = try findManagedSkillDirectory(skillId: skillId, in: activeRoot) ??
            activeRoot.appendingPathComponent(preferredSlug, isDirectory: true)

        if activeRoot.standardizedFileURL.path != disabledRoot.standardizedFileURL.path {
            try removeDisabledExports(skillId: skillId,
                                      baseName: destination.lastPathComponent,
                                      in: disabledRoot)
        }

        if fileManager.fileExists(atPath: destination.path) {
            guard try isManagedDirectory(destination, skillId: skillId) else {
                throw EngineError.unmanagedDestination(destination)
            }
            try fileManager.removeItem(at: destination)
        }

        try copyDirectory(canonicalDirectory, to: destination)

        let hash = try SkillDigest.sha256Hex(forSkillDirectory: destination, fileManager: fileManager)
        let manifest = SkillSyncManifest(skillId: skillId,
                                         canonical: false,
                                         tool: location.locationId,
                                         lastSyncAt: Date(),
                                         lastSyncedHash: hash)
        try SkillSyncManifestIO.save(manifest, to: destination, fileManager: fileManager)
    }

    func ensureCanonicalManifest(skillId: String, canonicalDirectory: URL) throws {
        guard fileManager.fileExists(atPath: canonicalDirectory.path) else {
            throw EngineError.invalidCanonicalSkill("Missing canonical directory: \(canonicalDirectory.path(percentEncoded: false))")
        }
        let values = try canonicalDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw EngineError.archiveSkillsRequireMaterialization
        }

        if let existing = try SkillSyncManifestIO.load(from: canonicalDirectory, fileManager: fileManager),
           existing.managedBy == SkillSyncManifest.managedByValue {
            return
        }

        let hash = try SkillDigest.sha256Hex(forSkillDirectory: canonicalDirectory, fileManager: fileManager)
        let manifest = SkillSyncManifest(skillId: skillId,
                                         canonical: true,
                                         tool: SkillSyncManifest.canonicalTool,
                                         lastSyncAt: Date(),
                                         lastSyncedHash: hash)
        try SkillSyncManifestIO.save(manifest, to: canonicalDirectory, fileManager: fileManager)
    }

    func syncSkill(skillId: String,
                   preferredSlug: String,
                   canonicalDirectory: URL,
                   enabledLocationIds: Set<String>,
                   locations: [SkillSyncLocationDescriptor],
                   forceSource: String?) throws -> SyncOutcome {
        var manifest = try loadOrCreateCanonicalManifest(expectedSkillId: skillId, canonicalDirectory: canonicalDirectory)
        guard let baselineHash = manifest.lastSyncedHash else {
            throw EngineError.invalidCanonicalSkill("Canonical manifest is missing lastSyncedHash.")
        }
        let canonicalHash = try SkillDigest.sha256Hex(forSkillDirectory: canonicalDirectory, fileManager: fileManager)

        var availableLocations: [String: (directory: URL, hash: String, displayName: String)] = [
            SkillSyncManifest.canonicalTool: (canonicalDirectory, canonicalHash, "Bundler")
        ]
        var missingExports: [SkillSyncLocationDescriptor] = []

        for location in locations where enabledLocationIds.contains(location.locationId) {
            if let dir = try findManagedSkillDirectory(skillId: skillId, in: location.rootURL) {
                let hash = try SkillDigest.sha256Hex(forSkillDirectory: dir, fileManager: fileManager)
                availableLocations[location.locationId] = (dir, hash, location.displayName)
            } else {
                missingExports.append(location)
            }
        }

        let changedLocations = availableLocations
            .filter { $0.value.hash != baselineHash }
            .map(\.key)
        let source = forceSource ?? (changedLocations.count == 1 ? changedLocations.first : nil)

        if source == nil, !changedLocations.isEmpty {
            let states = buildSyncStates(baselineHash: baselineHash, locations: availableLocations)
            let conflict = NativeSkillsSyncConflict(skillId: skillId,
                                                    slug: preferredSlug,
                                                    baselineHash: baselineHash,
                                                    enabledLocationIds: enabledLocationIds,
                                                    states: states)
            return .conflict(conflict)
        }

        if let source {
            guard let sourceEntry = availableLocations[source] else {
                throw EngineError.missingManagedExport(source)
                return .upToDate
            }

            var winnerHash = canonicalHash
            switch source {
            case SkillSyncManifest.canonicalTool:
                winnerHash = canonicalHash
            default:
                try overwriteCanonicalSkill(canonicalDirectory: canonicalDirectory, from: sourceEntry.directory)
                winnerHash = try SkillDigest.sha256Hex(forSkillDirectory: canonicalDirectory, fileManager: fileManager)
            }

            manifest.managedBy = SkillSyncManifest.managedByValue
            manifest.canonical = true
            manifest.tool = SkillSyncManifest.canonicalTool
            manifest.lastSyncAt = Date()
            manifest.lastSyncedHash = winnerHash
            try SkillSyncManifestIO.save(manifest, to: canonicalDirectory, fileManager: fileManager)

            for location in locations where enabledLocationIds.contains(location.locationId) {
                try syncExport(for: location,
                               skillId: skillId,
                               preferredSlug: preferredSlug,
                               canonicalDirectory: canonicalDirectory,
                               winnerHash: winnerHash,
                               source: source,
                               existingDirectory: availableLocations[location.locationId]?.directory)
            }

            return .propagated(source: source)
        }

        guard !missingExports.isEmpty else { return .upToDate }
        var created: [String] = []
        for tool in missingExports {
            try exportSkillDirectory(from: canonicalDirectory,
                                     preferredSlug: preferredSlug,
                                     skillId: skillId,
                                     to: tool)
            created.append(tool.locationId)
        }
        return .exportsCreated(created)
    }

    private func buildSyncStates(baselineHash: String,
                                 locations: [String: (directory: URL, hash: String, displayName: String)]) -> [NativeSkillsSyncState] {
        let sorted = locations.keys.sorted()
        return sorted.compactMap { locationId in
            guard let entry = locations[locationId] else { return nil }
            return NativeSkillsSyncState(locationId: locationId,
                                         displayName: entry.displayName,
                                         directoryPath: entry.directory.path(percentEncoded: false),
                                         currentHash: entry.hash,
                                         changedFromBaseline: entry.hash != baselineHash)
        }
    }

    private func syncExport(for location: SkillSyncLocationDescriptor,
                            skillId: String,
                            preferredSlug: String,
                            canonicalDirectory: URL,
                            winnerHash: String,
                            source: String,
                            existingDirectory: URL?) throws {
        if source == location.locationId, let existingDirectory {
            var manifest = SkillSyncManifest(skillId: skillId,
                                             canonical: false,
                                             tool: location.locationId,
                                             lastSyncAt: Date(),
                                             lastSyncedHash: winnerHash)
            if let existing = try SkillSyncManifestIO.load(from: existingDirectory, fileManager: fileManager),
               existing.managedBy == SkillSyncManifest.managedByValue {
                manifest = existing
                manifest.lastSyncAt = Date()
                manifest.lastSyncedHash = winnerHash
                manifest.canonical = false
                manifest.tool = location.locationId
            }
            try SkillSyncManifestIO.save(manifest, to: existingDirectory, fileManager: fileManager)
            return
        }

        try exportSkillDirectory(from: canonicalDirectory,
                                 preferredSlug: preferredSlug,
                                 skillId: skillId,
                                 to: location)
    }

    private func loadOrCreateCanonicalManifest(expectedSkillId: String, canonicalDirectory: URL) throws -> SkillSyncManifest {
        try ensureCanonicalManifest(skillId: expectedSkillId, canonicalDirectory: canonicalDirectory)
        var manifest = try SkillSyncManifestIO.load(from: canonicalDirectory, fileManager: fileManager) ??
            SkillSyncManifest(skillId: expectedSkillId, canonical: true, tool: SkillSyncManifest.canonicalTool)

        if manifest.skillId != expectedSkillId || manifest.managedBy != SkillSyncManifest.managedByValue {
            manifest = SkillSyncManifest(skillId: expectedSkillId, canonical: true, tool: SkillSyncManifest.canonicalTool)
        }

        if manifest.lastSyncedHash == nil {
            let hash = try SkillDigest.sha256Hex(forSkillDirectory: canonicalDirectory, fileManager: fileManager)
            manifest.lastSyncedHash = hash
            manifest.lastSyncAt = Date()
            manifest.canonical = true
            manifest.tool = SkillSyncManifest.canonicalTool
            try SkillSyncManifestIO.save(manifest, to: canonicalDirectory, fileManager: fileManager)
        }

        return manifest
    }

    private func overwriteCanonicalSkill(canonicalDirectory: URL, from sourceDirectory: URL) throws {
        let contents = try fileManager.contentsOfDirectory(at: canonicalDirectory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [])
        for item in contents {
            if item.lastPathComponent == SkillSyncManifestIO.directoryName {
                continue
            }
            try fileManager.removeItem(at: item)
        }
        try copyDirectory(sourceDirectory, to: canonicalDirectory)
    }

    private func findManagedSkillDirectory(skillId: String, in root: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: root.path) else { return nil }

        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                      options: [.skipsHiddenFiles],
                                                      errorHandler: { _, _ in true }) else {
            return nil
        }

        var seenDirectories = Set<String>()

        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isDirectory == true else { continue }

            let key = item.standardizedFileURL.path
            guard seenDirectories.insert(key).inserted else { continue }

            let skillFile = item.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillFile.path) else { continue }

            if let manifest = try SkillSyncManifestIO.load(from: item, fileManager: fileManager),
               manifest.managedBy == SkillSyncManifest.managedByValue,
               manifest.skillId == skillId {
                return item
            }
            enumerator.skipDescendants()
        }

        return nil
    }

    private func findManagedSkillDirectories(skillId: String, in root: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                      options: [.skipsHiddenFiles],
                                                      errorHandler: { _, _ in true }) else {
            return []
        }

        var matches: [URL] = []
        var seenDirectories = Set<String>()

        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isDirectory == true else { continue }

            let key = item.standardizedFileURL.path
            guard seenDirectories.insert(key).inserted else { continue }

            let skillFile = item.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillFile.path) else { continue }

            if let manifest = try SkillSyncManifestIO.load(from: item, fileManager: fileManager),
               manifest.managedBy == SkillSyncManifest.managedByValue,
               manifest.skillId == skillId {
                matches.append(item)
            }
            enumerator.skipDescendants()
        }

        return matches
    }

    private func removeDisabledExports(skillId: String,
                                       baseName: String,
                                       in disabledRoot: URL) throws {
        guard fileManager.fileExists(atPath: disabledRoot.path) else { return }

        var targets = Set(try findManagedSkillDirectories(skillId: skillId, in: disabledRoot)
            .map { $0.standardizedFileURL })
        let prefix = baseName + "-"

        let items = try fileManager.contentsOfDirectory(at: disabledRoot,
                                                        includingPropertiesForKeys: [.isDirectoryKey,
                                                                                      .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles])
        for item in items {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                continue
            }
            guard values.isDirectory == true else { continue }

            let name = item.lastPathComponent
            if name == baseName {
                targets.insert(item.standardizedFileURL)
                continue
            }

            if name.hasPrefix(prefix) {
                let suffix = String(name.dropFirst(prefix.count))
                if isTimestampSuffix(suffix) {
                    targets.insert(item.standardizedFileURL)
                }
            }
        }

        for target in targets {
            try fileManager.removeItem(at: target)
        }
    }

    private func isTimestampSuffix(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil {
            return true
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value) != nil
    }

    private func uniqueDestination(for slug: String, in disabledRoot: URL) -> URL {
        let base = disabledRoot.appendingPathComponent(slug, isDirectory: true)
        if !fileManager.fileExists(atPath: base.path) {
            return base
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
        return disabledRoot.appendingPathComponent("\(slug)-\(stamp)", isDirectory: true)
    }

    private func isManagedDirectory(_ url: URL, skillId: String) throws -> Bool {
        guard let manifest = try SkillSyncManifestIO.load(from: url, fileManager: fileManager) else { return false }
        guard manifest.managedBy == SkillSyncManifest.managedByValue else { return false }
        return manifest.skillId == skillId
    }

    private func copyDirectory(_ source: URL, to destination: URL) throws {
        try ensureDirectoryExists(destination)

        guard let enumerator = fileManager.enumerator(at: source,
                                                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                      options: [],
                                                      errorHandler: { _, _ in true }) else {
            return
        }

        while let item = enumerator.nextObject() as? URL {
            let relative = relativePath(item, base: source)
            if shouldExclude(relativePath: relative) {
                if item.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw SkillDigestError.containsSymlink(relative)
            }

            let target = destination.appendingPathComponent(relative, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try ensureDirectoryExists(target)
            } else {
                try ensureDirectoryExists(target.deletingLastPathComponent())
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    private func shouldExclude(relativePath: String) -> Bool {
        guard !relativePath.isEmpty else { return true }
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components where component == SkillSyncManifestIO.directoryName || component == "__MACOSX" || component == ".DS_Store" {
            return true
        }
        return false
    }

    private func relativePath(_ url: URL, base: URL) -> String {
        let standardizedSelf = url.standardizedFileURL
        let standardizedBase = base.standardizedFileURL
        let selfComponents = standardizedSelf.pathComponents
        let baseComponents = standardizedBase.pathComponents

        if selfComponents.count < baseComponents.count {
            return standardizedSelf.lastPathComponent
        }

        for (lhs, rhs) in zip(baseComponents, selfComponents) where lhs != rhs {
            return standardizedSelf.lastPathComponent
        }

        let relativeComponents = selfComponents.dropFirst(baseComponents.count)
        return relativeComponents.joined(separator: "/")
    }
}
