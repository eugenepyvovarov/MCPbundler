//
//  SkillDigest.swift
//  MCP Bundler
//
//  Provides stable hashing for skill directories to support bidirectional sync decisions.
//

import CryptoKit
import Foundation

nonisolated enum SkillDigestError: LocalizedError {
    case baseIsNotDirectory
    case baseIsNotFile
    case containsSymlink(String)

    var errorDescription: String? {
        switch self {
        case .baseIsNotDirectory:
            return "Skill digest base URL is not a directory."
        case .baseIsNotFile:
            return "Skill digest base URL is not a file."
        case .containsSymlink(let path):
            return "Skill contains unsupported symlink at \(path)."
        }
    }
}

nonisolated struct SkillDigest {
    nonisolated struct Options: Hashable {
        var failOnSymlinks: Bool = true
        var excludedPathComponents: Set<String> = [SkillSyncManifestIO.directoryName, "__MACOSX", ".DS_Store"]

        init() { }
    }

    static func sha256Hex(forSkillDirectory directory: URL,
                          options: Options = Options(),
                          fileManager: FileManager = .default) throws -> String {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw SkillDigestError.baseIsNotDirectory
        }

        let entries = try collectFiles(in: directory, options: options, fileManager: fileManager)
            .sorted(by: { $0.relativePath < $1.relativePath })

        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data(entry.relativePath.utf8))
            hasher.update(data: Data([0]))

            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024)
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }

            hasher.update(data: Data([0]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(forFile file: URL, fileManager: FileManager = .default) throws -> String {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw SkillDigestError.containsSymlink(file.path(percentEncoded: false))
        }
        guard values.isRegularFile == true else {
            throw SkillDigestError.baseIsNotFile
        }

        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct FileEntry {
        let url: URL
        let relativePath: String
    }

    private static func collectFiles(in directory: URL,
                                     options: Options,
                                     fileManager: FileManager) throws -> [FileEntry] {
        var results: [FileEntry] = []
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                      options: [],
                                                      errorHandler: { _, _ in true }) else {
            return []
        }

        while let item = enumerator.nextObject() as? URL {
            let relative = relativePath(item, base: directory)
            if isExcluded(relativePath: relative, options: options) {
                if item.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if options.failOnSymlinks {
                    throw SkillDigestError.containsSymlink(relative)
                }
                continue
            }

            if values.isDirectory == true {
                continue
            }

            results.append(FileEntry(url: item, relativePath: relative))
        }

        return results
    }

    private static func isExcluded(relativePath: String, options: Options) -> Bool {
        guard !relativePath.isEmpty else { return true }
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components where options.excludedPathComponents.contains(component) {
            return true
        }
        return false
    }

    private static func relativePath(_ url: URL, base: URL) -> String {
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
