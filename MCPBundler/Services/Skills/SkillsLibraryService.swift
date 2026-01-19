//
//  SkillsLibraryService.swift
//  MCP Bundler
//
//  Provides discovery and direct file/archive reads for the global skills library.
//

import Foundation
import os.log
import UniformTypeIdentifiers

private let skillsLog = Logger(subsystem: "mcp-bundler", category: "skills.registry")

struct SkillResourceInfo: Hashable {
    let relativePath: String
    let mimeType: String?
}

struct SkillInfo: Hashable {
    let slug: String
    let name: String
    let description: String
    let license: String?
    let allowedTools: [String]
    let extra: [String: String]
    let resources: [SkillResourceInfo]
    let source: URL
    let isArchive: Bool
}

enum SkillsLibraryError: LocalizedError {
    case missingSkill(String)
    case missingResource(slug: String, path: String)
    case invalidResourcePath
    case invalidSkill(String)
    case duplicateSlug(String)

    var errorDescription: String? {
        switch self {
        case .missingSkill(let slug):
            return "Skill with slug '\(slug)' not found."
        case .missingResource(let slug, let path):
            return "Resource '\(path)' for skill '\(slug)' not found."
        case .invalidResourcePath:
            return "Resource path is invalid."
        case .invalidSkill(let reason):
            return "Skill is invalid: \(reason)"
        case .duplicateSlug(let slug):
            return "Another skill already uses the slug '\(slug)'."
        }
    }
}

actor SkillsLibraryService {
    struct ResourceReadResult {
        let data: Data
        let mimeType: String?
        let isTextUTF8: Bool
    }

    private enum SkillSource {
        case directory(URL)
        case archive(URL)
    }

    private struct SkillEntry {
        struct ResourceRecord {
            let info: SkillResourceInfo
            let archivePath: String?
        }

        let info: SkillInfo
        let source: SkillSource
        let instructions: String
        let resourceLookup: [String: ResourceRecord]
    }

    private let fileManager: FileManager
    private(set) var root: URL
    private var entries: [String: SkillEntry] = [:]
    private var orderedSlugs: [String] = []

    init(root: URL = skillsLibraryURL(), fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.root = root
    }

    func reload() async throws {
        try ensureRootExists()
        var newEntries: [String: SkillEntry] = [:]
        var sortedSlugs: [String] = []

        let directorySkills = try discoverDirectorySkills()
        let archiveSkills = try discoverArchiveSkills()

        let combined = directorySkills + archiveSkills

        for entry in combined.sorted(by: { $0.info.slug < $1.info.slug }) {
            if newEntries[entry.info.slug] != nil {
                skillsLog.error("Duplicate skill slug '\(entry.info.slug)', ignoring later source")
                continue
            }
            newEntries[entry.info.slug] = entry
            sortedSlugs.append(entry.info.slug)
        }

        entries = newEntries
        orderedSlugs = sortedSlugs
    }

    func list() async -> [SkillInfo] {
        orderedSlugs.compactMap { entries[$0]?.info }
    }

    func readInstructions(slug: String) throws -> String {
        guard let entry = entries[slug] else {
            throw SkillsLibraryError.missingSkill(slug)
        }
        return entry.instructions
    }

    func readResource(slug: String, relPath: String) throws -> ResourceReadResult {
        guard let entry = entries[slug] else {
            throw SkillsLibraryError.missingSkill(slug)
        }
        guard let record = entry.resourceLookup[relPath] else {
            throw SkillsLibraryError.missingResource(slug: slug, path: relPath)
        }
        switch entry.source {
        case .directory(let dir):
            return try readDirectoryResource(record.info, base: dir, slug: entry.info.slug)
        case .archive(let archiveURL):
            guard let archivePath = record.archivePath else {
                throw SkillsLibraryError.invalidSkill("Archive mapping missing for \(relPath)")
            }
            return try readArchiveResource(record.info, archiveURL: archiveURL, archivePath: archivePath, slug: entry.info.slug)
        }
    }

    private func ensureRootExists() throws {
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    private func discoverDirectorySkills() throws -> [SkillEntry] {
        var skills: [SkillEntry] = []
        let enumerator = fileManager.enumerator(at: root,
                                                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                                options: [.skipsHiddenFiles],
                                                errorHandler: { url, error in
                                                    skillsLog.error("Enumerator error at \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                                    return true
                                                })

        var candidateDirectories = Set<URL>()

        while let item = enumerator?.nextObject() as? URL {
            if shouldSkip(url: item) {
                if item.hasDirectoryPath {
                    enumerator?.skipDescendants()
                }
                continue
            }

            if item.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame {
                candidateDirectories.insert(item.deletingLastPathComponent())
                enumerator?.skipDescendants()
            }
        }

        for directory in candidateDirectories {
            do {
                let entry = try loadDirectorySkill(at: directory)
                skills.append(entry)
            } catch {
                skillsLog.error("Failed to load skill at \(directory.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return skills
    }

    private func discoverArchiveSkills() throws -> [SkillEntry] {
        var skills: [SkillEntry] = []
        let contents = try fileManager.contentsOfDirectory(at: root,
                                                           includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles])

        let archives = contents.filter { url in
            guard !shouldSkip(url: url) else { return false }
            guard !url.hasDirectoryPath else { return false }
            let ext = url.pathExtension.lowercased()
            return ext == "zip" || ext == "skill"
        }

        for archive in archives {
            do {
                let destination = try SkillArchiveMaterializer.materializeArchive(at: archive,
                                                                                 to: root,
                                                                                 skillId: UUID().uuidString,
                                                                                 fileManager: fileManager)
                let entry = try loadDirectorySkill(at: destination)
                skills.append(entry)
                skillsLog.info("Materialized archive skill '\(archive.lastPathComponent, privacy: .public)' to '\(destination.lastPathComponent, privacy: .public)'")
            } catch {
                skillsLog.error("Failed to materialize archived skill at \(archive.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return skills
    }

    private func loadDirectorySkill(at directory: URL) throws -> SkillEntry {
        let skillFile = directory.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: skillFile.path) else {
            throw SkillsLibraryError.invalidSkill("Missing SKILL.md")
        }

        let data = try Data(contentsOf: skillFile)
        let document = try parseSkillDocument(data: data, sourcePath: skillFile.path)

        let resources = try enumerateDirectoryResources(at: directory, excluding: Set(["SKILL.md"]))
        var resourceLookup: [String: SkillEntry.ResourceRecord] = [:]
        for resource in resources {
            resourceLookup[resource.relativePath] = SkillEntry.ResourceRecord(info: resource, archivePath: nil)
        }

        let info = SkillInfo(slug: document.slug,
                             name: document.name,
                             description: document.description,
                             license: document.license,
                             allowedTools: document.allowedTools,
                             extra: document.extra,
                             resources: resources,
                             source: directory,
                             isArchive: false)

        return SkillEntry(info: info,
                          source: .directory(directory),
                          instructions: document.instructions,
                          resourceLookup: resourceLookup)
    }

    private func loadArchiveSkill(at archive: URL) throws -> SkillEntry {
        let entries = try listArchiveEntries(at: archive)
        guard !entries.isEmpty else {
            throw SkillsLibraryError.invalidSkill("Archive \(archive.lastPathComponent) is empty")
        }

        var fileEntries: [(path: String, isDirectory: Bool)] = []
        for raw in entries {
            guard var parsed = parseArchiveEntry(raw) else { continue }
            if shouldSkipArchiveEntry(parsed.path) {
                continue
            }
            if parsed.isDirectory && parsed.path.isEmpty {
                continue
            }
            fileEntries.append(parsed)
        }

        let skillCandidates = fileEntries.filter { !$0.isDirectory && ($0.path as NSString).lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame }
        guard skillCandidates.count == 1, let skillEntry = skillCandidates.first else {
            throw SkillsLibraryError.invalidSkill("Archive \(archive.lastPathComponent) must contain exactly one SKILL.md")
        }

        let rootComponent = ((skillEntry.path as NSString).deletingLastPathComponent)
        if !rootComponent.isEmpty && rootComponent.contains("/") {
            throw SkillsLibraryError.invalidSkill("SKILL.md must be at archive root or within a single top-level directory in \(archive.lastPathComponent)")
        }

        let skillData = try readArchiveEntry(at: archive, entryPath: skillEntry.path)
        let document = try parseSkillDocument(data: skillData, sourcePath: "\(archive.path)#\(skillEntry.path)")

        var resources: [SkillResourceInfo] = []
        var lookup: [String: SkillEntry.ResourceRecord] = [:]

        for entry in fileEntries {
            if entry.isDirectory {
                continue
            }
            if entry.path == skillEntry.path {
                continue
            }

            guard let relative = relativeArchivePath(entry.path, root: rootComponent) else {
                continue
            }

            guard isValidRelativePath(relative) else {
                continue
            }

            let info = SkillResourceInfo(relativePath: relative, mimeType: mimeType(forPath: relative))
            resources.append(info)
            lookup[relative] = SkillEntry.ResourceRecord(info: info, archivePath: entry.path)
        }

        resources.sort { $0.relativePath < $1.relativePath }

        let info = SkillInfo(slug: document.slug,
                             name: document.name,
                             description: document.description,
                             license: document.license,
                             allowedTools: document.allowedTools,
                             extra: document.extra,
                             resources: resources,
                             source: archive,
                             isArchive: true)

        return SkillEntry(info: info,
                          source: .archive(archive),
                          instructions: document.instructions,
                          resourceLookup: lookup)
    }

    private func listArchiveEntries(at archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        defer {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let message = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw SkillsLibraryError.invalidSkill("Failed to list archive \(archive.lastPathComponent): \(message)")
        }

        guard let output = String(data: stdoutData, encoding: .utf8) else {
            throw SkillsLibraryError.invalidSkill("Archive \(archive.lastPathComponent) listing encoding error")
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func readArchiveEntry(at archive: URL, entryPath: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-p", archive.path, entryPath]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        defer {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let message = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw SkillsLibraryError.invalidSkill("Failed to read \(entryPath) from \(archive.lastPathComponent): \(message)")
        }

        return stdoutData
    }

    private func parseArchiveEntry(_ raw: String) -> (path: String, isDirectory: Bool)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory = false
        if trimmed.hasSuffix("/") {
            isDirectory = true
            trimmed.removeLast()
        }
        return (path: trimmed, isDirectory: isDirectory)
    }

    private func relativeArchivePath(_ fullPath: String, root: String) -> String? {
        if root.isEmpty {
            return fullPath
        }
        if fullPath == root {
            return nil
        }
        guard fullPath.hasPrefix(root + "/") else {
            return nil
        }
        let start = fullPath.index(fullPath.startIndex, offsetBy: root.count + 1)
        return String(fullPath[start...])
    }

    private func shouldSkipArchiveEntry(_ path: String) -> Bool {
        if path.isEmpty {
            return true
        }
        let components = path.split(separator: "/")
        for component in components {
            let value = String(component)
            if value == "__MACOSX" || value == ".DS_Store" || value == ".." {
                return true
            }
        }
        return false
    }

    private func enumerateDirectoryResources(at directory: URL, excluding excludedNames: Set<String>) throws -> [SkillResourceInfo] {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles],
                                                      errorHandler: { url, error in
                                                          skillsLog.error("Resource enumeration error at \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                                          return true
                                                      }) else {
            return []
        }

        var resources: [SkillResourceInfo] = []

        while let item = enumerator.nextObject() as? URL {
            if shouldSkip(url: item) {
                if item.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            if item.hasDirectoryPath {
                continue
            }

            let relative = item.path(relativeTo: directory)
            guard !excludedNames.contains(item.lastPathComponent) else { continue }
            guard isValidRelativePath(relative) else { continue }

            let info = SkillResourceInfo(relativePath: relative, mimeType: mimeType(forPath: relative))
            resources.append(info)
        }

        return resources.sorted(by: { $0.relativePath < $1.relativePath })
    }

    private func readDirectoryResource(_ resource: SkillResourceInfo, base: URL, slug: String) throws -> ResourceReadResult {
        let resolved = resolveRelative(resource.relativePath, base: base)
        guard let resolved, fileManager.fileExists(atPath: resolved.path) else {
            throw SkillsLibraryError.missingResource(slug: slug, path: resource.relativePath)
        }
        let data = try Data(contentsOf: resolved)
        let isText = data.isProbablyTextUTF8()
        return ResourceReadResult(data: data, mimeType: resource.mimeType, isTextUTF8: isText)
    }

    private func readArchiveResource(_ resource: SkillResourceInfo, archiveURL: URL, archivePath: String, slug: String) throws -> ResourceReadResult {
        let data = try readArchiveEntry(at: archiveURL, entryPath: archivePath)
        let isText = data.isProbablyTextUTF8()
        return ResourceReadResult(data: data, mimeType: resource.mimeType, isTextUTF8: isText)
    }

    private func shouldSkip(url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == ".DS_Store" {
            return true
        }
        if url.pathComponents.contains("__MACOSX") {
            return true
        }
        return false
    }

    private func isValidRelativePath(_ path: String) -> Bool {
        if path.isEmpty {
            return false
        }
        if path.hasPrefix("/") {
            return false
        }
        let components = path.split(separator: "/")
        guard !components.contains("..") else {
            return false
        }
        return true
    }

    private func resolveRelative(_ path: String, base: URL) -> URL? {
        guard isValidRelativePath(path) else { return nil }
        let components = path.split(separator: "/").map(String.init)
        var url = base
        for component in components {
            url.appendPathComponent(component, isDirectory: false)
        }
        let standardized = url.standardizedFileURL
        let basePath = base.standardizedFileURL.path
        guard standardized.path.hasPrefix(basePath) else { return nil }
        return standardized
    }

    private func mimeType(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        guard let type = UTType(filenameExtension: ext) else {
            return nil
        }
        return type.preferredMIMEType
    }

    private func parseSkillDocument(data: Data, sourcePath: String) throws -> (slug: String,
                                                                               name: String,
                                                                               description: String,
                                                                               license: String?,
                                                                               allowedTools: [String],
                                                                               extra: [String: String],
                                                                               instructions: String) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw SkillsLibraryError.invalidSkill("SKILL.md at \(sourcePath) is not valid UTF-8/UTF-16 text")
        }

        let (frontMatterLines, body) = try splitFrontMatterAndBody(from: text)
        let parsed = try parseFrontMatter(lines: frontMatterLines, sourcePath: sourcePath)
        let slug = try slugify(parsed.name, sourcePath: sourcePath)

        return (slug: slug,
                name: parsed.name,
                description: parsed.description,
                license: parsed.license,
                allowedTools: parsed.allowedTools,
                extra: parsed.extra,
                instructions: body)
    }

    private func splitFrontMatterAndBody(from text: String) throws -> ([String], String) {
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
        var license: String?
        var allowedTools: [String]
        var extra: [String: String]
    }

    private func parseFrontMatter(lines: [String], sourcePath: String) throws -> FrontMatter {
        var name: String?
        var description: String?
        var license: String?
        var allowedTools: [String] = []
        var extra: [String: String] = [:]
        var currentListKey: String?
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

        func flushList() {
            guard let key = currentListKey else { return }
            if key == "allowed-tools" {
                allowedTools = listAccumulator
            } else if !listAccumulator.isEmpty {
                extra[key] = listAccumulator.joined(separator: "\n")
            }
            currentListKey = nil
            listAccumulator.removeAll()
        }

        func assignValue(_ value: String, to key: String) {
            switch key {
            case "name":
                name = value
            case "description":
                description = value
            case "license":
                license = value
            case "allowed-tools":
                allowedTools = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            default:
                extra[key] = value
            }
        }

        var listAccumulator: [String] = []

        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")

            if let key = currentBlockKey {
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

            if trimmed.hasPrefix("- ") {
                guard let key = currentListKey else { continue }
                let value = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                listAccumulator.append(value)
                continue
            }

            if let colonIndex = line.firstIndex(of: ":") {
                flushBlock()
                flushList()
                currentListKey = nil

                let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

                if value == "|" || value == "|-" || value == ">" || value == ">-" {
                    currentBlockKey = key
                    currentBlockIndent = indentationLevel(of: line) + 2
                    blockBuffer = []
                    continue
                }

                if value == "[]" {
                    if key == "allowed-tools" {
                        allowedTools = []
                    } else {
                        extra[key] = "[]"
                    }
                    continue
                }

                if value.isEmpty {
                    currentListKey = key
                    continue
                }

                if value.hasPrefix("[") && value.hasSuffix("]") {
                    let inner = value.dropFirst().dropLast()
                    let list = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if key == "allowed-tools" {
                        allowedTools = list
                    } else {
                        extra[key] = list.joined(separator: ",")
                    }
                    continue
                }

                assignValue(value, to: key)
            }
        }

        flushList()
        flushBlock()

        guard let resolvedName = name, !resolvedName.isEmpty else {
            throw SkillsLibraryError.invalidSkill("Front matter missing 'name' at \(sourcePath)")
        }

        guard let resolvedDescription = description, !resolvedDescription.isEmpty else {
            throw SkillsLibraryError.invalidSkill("Front matter missing 'description' at \(sourcePath)")
        }

        return FrontMatter(name: resolvedName,
                           description: resolvedDescription,
                           license: license,
                           allowedTools: allowedTools,
                           extra: extra)
    }

    private func indentationLevel(of line: String) -> Int {
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

    private func slugify(_ name: String, sourcePath: String) throws -> String {
        let lowered = name.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        var slug = String(allowed)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else {
            throw SkillsLibraryError.invalidSkill("Skill name produces empty slug at \(sourcePath)")
        }
        return slug
    }
}

nonisolated func skillsLibraryURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("Lifeisgoodlabs.MCP-Bundler", isDirectory: true)
    let skillsDir = dir.appendingPathComponent("Skills", isDirectory: true)
    if !FileManager.default.fileExists(atPath: skillsDir.path) {
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    }
    return skillsDir
}

private extension Data {
    func isProbablyTextUTF8() -> Bool {
        if isEmpty {
            return true
        }
        if contains(0) {
            return false
        }
        return String(data: self, encoding: .utf8) != nil
    }
}

private extension URL {
    func path(relativeTo base: URL) -> String {
        let standardizedSelf = self.standardizedFileURL
        let standardizedBase = base.standardizedFileURL
        let selfComponents = standardizedSelf.pathComponents
        let baseComponents = standardizedBase.pathComponents
        var matches = true
        if selfComponents.count < baseComponents.count {
            matches = false
        } else {
            for (lhs, rhs) in zip(baseComponents, selfComponents) {
                if lhs != rhs {
                    matches = false
                    break
                }
            }
        }
        guard matches else {
            return standardizedSelf.lastPathComponent
        }
        let relativeComponents = selfComponents.dropFirst(baseComponents.count)
        return relativeComponents.joined(separator: "/")
    }
}
