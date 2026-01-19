//
//  SkillArchiveMaterializer.swift
//  MCP Bundler
//
//  Materializes .zip/.skill archives into directory skills in the canonical skills library.
//

import Foundation

nonisolated enum SkillArchiveMaterializerError: LocalizedError {
    case invalidArchive(String)
    case invalidStructure(String)
    case extractionFailed(String)
    case missingSkillDirectory

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let message):
            return "Invalid archive: \(message)"
        case .invalidStructure(let message):
            return "Invalid skill structure: \(message)"
        case .extractionFailed(let message):
            return "Failed to extract archive: \(message)"
        case .missingSkillDirectory:
            return "Extracted skill directory is missing."
        }
    }
}

nonisolated enum SkillArchiveMaterializer {
    static func materializeArchive(at archiveURL: URL,
                                   to destinationRoot: URL,
                                   skillId: String? = nil,
                                   fileManager: FileManager = .default) throws -> URL {
        let listing = try listArchiveEntries(at: archiveURL)
        let skillEntry = try resolveSkillEntry(from: listing, archiveName: archiveURL.lastPathComponent)
        let extractionRoot = try createExtractionRoot(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: extractionRoot)
        }

        try extractArchive(at: archiveURL, to: extractionRoot)

        let skillDirectory: URL
        if skillEntry.rootComponent.isEmpty {
            skillDirectory = extractionRoot
        } else {
            skillDirectory = extractionRoot.appendingPathComponent(skillEntry.rootComponent, isDirectory: true)
        }

        guard fileManager.fileExists(atPath: skillDirectory.path) else {
            throw SkillArchiveMaterializerError.missingSkillDirectory
        }

        let digest = try SkillDigest.sha256Hex(forSkillDirectory: skillDirectory, fileManager: fileManager)

        try ensureDirectoryExists(destinationRoot, fileManager: fileManager)
        let baseName = skillEntry.rootComponent.isEmpty ? archiveURL.deletingPathExtension().lastPathComponent : skillEntry.rootComponent
        let destination = uniqueDestination(for: baseName, in: destinationRoot, fileManager: fileManager)

        do {
            try fileManager.moveItem(at: skillDirectory, to: destination)
        } catch {
            try fileManager.copyItem(at: skillDirectory, to: destination)
        }

        if let skillId {
            let manifest = SkillSyncManifest(skillId: skillId,
                                             canonical: true,
                                             tool: SkillSyncManifest.canonicalTool,
                                             lastSyncAt: Date(),
                                             lastSyncedHash: digest)
            try SkillSyncManifestIO.save(manifest, to: destination, fileManager: fileManager)
        }

        stashOriginalArchiveIfNeeded(archiveURL: archiveURL,
                                     skillsRoot: destinationRoot,
                                     fileManager: fileManager)

        return destination
    }

    // MARK: - Archive inspection

    private struct SkillEntryInfo {
        let skillPath: String
        let rootComponent: String
    }

    private static func listArchiveEntries(at archiveURL: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archiveURL.path]
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
            throw SkillArchiveMaterializerError.invalidArchive(message)
        }

        guard let output = String(data: stdoutData, encoding: .utf8) else {
            throw SkillArchiveMaterializerError.invalidArchive("Archive listing encoding error")
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func resolveSkillEntry(from entries: [String], archiveName: String) throws -> SkillEntryInfo {
        var candidates: [String] = []
        for raw in entries {
            guard let parsed = parseArchiveEntry(raw) else { continue }
            if shouldSkipArchiveEntry(parsed.path) {
                continue
            }
            if !parsed.isDirectory, (parsed.path as NSString).lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame {
                candidates.append(parsed.path)
            }
        }

        guard candidates.count == 1, let skillPath = candidates.first else {
            throw SkillArchiveMaterializerError.invalidStructure("\(archiveName) must contain exactly one SKILL.md")
        }

        let rootComponent = (skillPath as NSString).deletingLastPathComponent
        if !rootComponent.isEmpty && rootComponent.contains("/") {
            throw SkillArchiveMaterializerError.invalidStructure("SKILL.md must be at archive root or within a single top-level directory")
        }

        if !rootComponent.isEmpty {
            for raw in entries {
                guard let parsed = parseArchiveEntry(raw) else { continue }
                if shouldSkipArchiveEntry(parsed.path) {
                    continue
                }
                if parsed.path == rootComponent {
                    continue
                }
                if !parsed.path.hasPrefix(rootComponent + "/") {
                    throw SkillArchiveMaterializerError.invalidStructure("Archive contains content outside '\(rootComponent)/'")
                }
            }
        }

        return SkillEntryInfo(skillPath: skillPath, rootComponent: rootComponent)
    }

    private static func parseArchiveEntry(_ raw: String) -> (path: String, isDirectory: Bool)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory = false
        if trimmed.hasSuffix("/") {
            isDirectory = true
            trimmed.removeLast()
        }
        return (path: trimmed, isDirectory: isDirectory)
    }

    private static func shouldSkipArchiveEntry(_ path: String) -> Bool {
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

    // MARK: - Extraction

    private static func extractArchive(at archiveURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", archiveURL.path, "-d", destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        defer {
            stderr.fileHandleForReading.closeFile()
        }

        if process.terminationStatus != 0 {
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw SkillArchiveMaterializerError.extractionFailed(message)
        }
    }

    private static func createExtractionRoot(fileManager: FileManager) throws -> URL {
        let root = fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("mcp-bundler-skill-\(UUID().uuidString)", isDirectory: true)
        try ensureDirectoryExists(directory, fileManager: fileManager)
        return directory
    }

    // MARK: - Paths

    private static func ensureDirectoryExists(_ url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func uniqueDestination(for baseName: String, in root: URL, fileManager: FileManager) -> URL {
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName)-\(counter)", isDirectory: true)
            counter += 1
        }

        return candidate
    }

    private static func stashOriginalArchiveIfNeeded(archiveURL: URL, skillsRoot: URL, fileManager: FileManager) {
        let standardizedArchive = archiveURL.standardizedFileURL
        let standardizedRoot = skillsRoot.standardizedFileURL
        guard standardizedArchive.path.hasPrefix(standardizedRoot.path) else { return }
        guard fileManager.fileExists(atPath: standardizedArchive.path) else { return }

        let stashDir = skillsRoot.appendingPathComponent(".archives", isDirectory: true)
        try? ensureDirectoryExists(stashDir, fileManager: fileManager)
        guard !standardizedArchive.path.hasPrefix(stashDir.standardizedFileURL.path) else { return }

        var destination = stashDir.appendingPathComponent(archiveURL.lastPathComponent, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            let baseName = archiveURL.deletingPathExtension().lastPathComponent
            let ext = archiveURL.pathExtension
            var counter = 2
            while fileManager.fileExists(atPath: destination.path) {
                let name = "\(baseName)-\(counter)"
                if ext.isEmpty {
                    destination = stashDir.appendingPathComponent(name, isDirectory: false)
                } else {
                    destination = stashDir.appendingPathComponent(name, isDirectory: false).appendingPathExtension(ext)
                }
                counter += 1
            }
        }

        try? fileManager.moveItem(at: archiveURL, to: destination)
    }
}
