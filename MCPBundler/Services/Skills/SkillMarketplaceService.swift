//
//  SkillMarketplaceService.swift
//  MCP Bundler
//
//  Fetches marketplace manifests from public GitHub repositories and installs skills.
//

import Foundation
import SwiftData

struct SkillMarketplaceRepository: Hashable, Sendable {
    let owner: String
    let repo: String
}

struct SkillGitHubFolderReference: Hashable, Sendable {
    let owner: String
    let repo: String
    let branch: String
    let path: String
}

struct SkillMarketplaceListing: Hashable, Sendable {
    let owner: String
    let repo: String
    let defaultBranch: String
    let document: SkillMarketplaceDocument
}

struct SkillMarketplaceInstallResult: Hashable, Sendable {
    let slug: String
    let destination: URL
}

struct SkillMarketplaceFetchResult: Hashable, Sendable {
    let listing: SkillMarketplaceListing
    let cacheUpdate: SkillMarketplaceCacheUpdate?
    let warningMessage: String?
}

struct SkillMarketplaceCacheUpdate: Hashable, Sendable {
    let manifestSHA: String?
    let defaultBranch: String
    let manifestJSON: String
    let skillNames: [String]
}

enum SkillMarketplaceError: LocalizedError, Sendable {
    case invalidGitHubURL
    case unsupportedGitHubURL
    case invalidRepositoryPath
    case invalidGitHubFolderURL
    case rateLimited(reset: Date?)
    case apiFailure(status: Int, message: String)
    case invalidMarketplaceDocument(String)
    case invalidPluginSource(String)
    case unsupportedContentEntry(String)
    case missingSkillFile
    case invalidSkill(String)

    var errorDescription: String? {
        switch self {
        case .invalidGitHubURL:
            return "GitHub URL is invalid."
        case .unsupportedGitHubURL:
            return "Marketplace source must be an https://github.com/{owner}/{repo} URL."
        case .invalidRepositoryPath:
            return "GitHub URL must include both owner and repo names."
        case .invalidGitHubFolderURL:
            return "GitHub URL must be a folder URL like https://github.com/{owner}/{repo}/tree/{branch}/{path}."
        case .rateLimited(let reset):
            if let reset {
                return "GitHub rate limit exceeded. Try again after \(SkillMarketplaceError.format(reset))."
            }
            return "GitHub rate limit exceeded. Try again later."
        case .apiFailure(let status, let message):
            return "GitHub API error (\(status)): \(message)"
        case .invalidMarketplaceDocument(let reason):
            return "Marketplace manifest is invalid: \(reason)"
        case .invalidPluginSource(let reason):
            return "Plugin source path is invalid: \(reason)"
        case .unsupportedContentEntry(let path):
            return "Marketplace content contains unsupported entry at \(path)."
        case .missingSkillFile:
            return "Downloaded skill is missing SKILL.md at its root."
        case .invalidSkill(let reason):
            return "Downloaded skill is invalid: \(reason)"
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct SkillMarketplaceService {
    private let session: URLSession
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, fileManager: FileManager = .default, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.fileManager = fileManager
        self.decoder = decoder
    }

    static func parseGitHubRepository(from raw: String) throws -> SkillMarketplaceRepository {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw SkillMarketplaceError.invalidGitHubURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }
        guard url.host?.lowercased() == "github.com" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 2 else {
            throw SkillMarketplaceError.invalidRepositoryPath
        }

        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard !owner.isEmpty, !repo.isEmpty else {
            throw SkillMarketplaceError.invalidRepositoryPath
        }

        return SkillMarketplaceRepository(owner: owner, repo: repo)
    }

    static func parseGitHubFolderURL(from raw: String) throws -> SkillGitHubFolderReference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw SkillMarketplaceError.invalidGitHubURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }
        guard url.host?.lowercased() == "github.com" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.split(separator: "/").map { component in
            String(component).removingPercentEncoding ?? String(component)
        }
        guard components.count >= 5 else {
            throw SkillMarketplaceError.invalidGitHubFolderURL
        }
        guard components[2] == "tree" else {
            throw SkillMarketplaceError.invalidGitHubFolderURL
        }

        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        let branch = components[3]
        let pathComponents = components[4...]
        guard !owner.isEmpty, !repo.isEmpty, !branch.isEmpty, !pathComponents.isEmpty else {
            throw SkillMarketplaceError.invalidGitHubFolderURL
        }

        let folderPath = pathComponents.joined(separator: "/")
        return SkillGitHubFolderReference(owner: owner,
                                          repo: repo,
                                          branch: branch,
                                          path: folderPath)
    }

    func fetchMarketplace(owner: String, repo: String) async throws -> SkillMarketplaceListing {
        let info = try await fetchRepositoryInfo(owner: owner, repo: repo)
        let document = try await fetchMarketplaceDocument(owner: owner, repo: repo, branch: info.defaultBranch)
        return SkillMarketplaceListing(owner: owner, repo: repo, defaultBranch: info.defaultBranch, document: document)
    }

    func fetchMarketplaceSkills(owner: String,
                                repo: String,
                                cachedManifestSHA: String?,
                                cachedMarketplaceJSON: String?,
                                cachedSkillNames: [String]?,
                                cachedDefaultBranch: String?) async throws -> SkillMarketplaceFetchResult {
        if let rawResult = try await fetchMarketplaceManifestRawFirst(owner: owner,
                                                                      repo: repo,
                                                                      cachedDefaultBranch: cachedDefaultBranch) {
            return try await resolveListing(owner: owner,
                                            repo: repo,
                                            defaultBranch: rawResult.branch,
                                            manifest: rawResult.manifest,
                                            cachedManifestSHA: cachedManifestSHA,
                                            cachedMarketplaceJSON: cachedMarketplaceJSON,
                                            cachedSkillNames: cachedSkillNames)
        }

        let info: RepositoryInfo
        do {
            info = try await fetchRepositoryInfo(owner: owner, repo: repo)
        } catch let error as SkillMarketplaceError {
            if case .rateLimited = error,
               let cachedMarketplaceJSON,
               let cachedSkillNames,
               let cachedDefaultBranch {
                let listing = try cachedListing(owner: owner,
                                                repo: repo,
                                                defaultBranch: cachedDefaultBranch,
                                                marketplaceJSON: cachedMarketplaceJSON,
                                                skillNames: cachedSkillNames)
                return SkillMarketplaceFetchResult(listing: listing,
                                                   cacheUpdate: nil,
                                                   warningMessage: error.localizedDescription)
            }
            throw error
        }

        let manifest: MarketplaceManifest
        do {
            manifest = try await fetchMarketplaceManifest(owner: owner,
                                                          repo: repo,
                                                          branch: info.defaultBranch,
                                                          cachedManifestSHA: cachedManifestSHA,
                                                          cachedManifestJSON: cachedMarketplaceJSON)
        } catch let error as SkillMarketplaceError {
            if case .rateLimited = error,
               let cachedMarketplaceJSON,
               let cachedSkillNames,
               let cachedDefaultBranch {
                let listing = try cachedListing(owner: owner,
                                                repo: repo,
                                                defaultBranch: cachedDefaultBranch,
                                                marketplaceJSON: cachedMarketplaceJSON,
                                                skillNames: cachedSkillNames)
                return SkillMarketplaceFetchResult(listing: listing,
                                                   cacheUpdate: nil,
                                                   warningMessage: error.localizedDescription)
            }
            throw error
        }

        return try await resolveListing(owner: owner,
                                        repo: repo,
                                        defaultBranch: info.defaultBranch,
                                        manifest: manifest,
                                        cachedManifestSHA: cachedManifestSHA,
                                        cachedMarketplaceJSON: cachedMarketplaceJSON,
                                        cachedSkillNames: cachedSkillNames)
    }

    func fetchSkillPreview(reference: SkillGitHubFolderReference) async throws -> SkillFrontMatterSummary {
        let normalizedPath = try normalizePluginSource(reference.path)
        let url = URL(string: "https://raw.githubusercontent.com/\(reference.owner)/\(reference.repo)/\(reference.branch)/\(normalizedPath)/SKILL.md")!
        do {
            let data = try await fetchRawData(from: url)
            return try SkillFrontMatterReader.parse(data: data, sourcePath: url.absoluteString)
        } catch let error as SkillMarketplaceError {
            if case .apiFailure(let status, _) = error, status == 404 {
                throw SkillMarketplaceError.missingSkillFile
            }
            throw error
        }
    }

    func installSkillFromGitHubFolder(_ reference: SkillGitHubFolderReference,
                                      existingSlugs: Set<String>,
                                      libraryRoot: URL = skillsLibraryURL()) async throws -> SkillMarketplaceInstallResult {
        let normalizedPath = try normalizePluginSource(reference.path)
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcp-bundler-skill-url-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = tempRoot.appendingPathComponent("skill", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try await downloadFolder(owner: reference.owner,
                                 repo: reference.repo,
                                 branch: reference.branch,
                                 path: normalizedPath,
                                 pluginRoot: normalizedPath,
                                 destinationRoot: stagingRoot)

        let skillFile = stagingRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: skillFile.path) else {
            throw SkillMarketplaceError.missingSkillFile
        }

        let skillData = try Data(contentsOf: skillFile)
        let summary = try SkillFrontMatterReader.parse(data: skillData, sourcePath: skillFile.path)
        let resolved = try resolveSlugConflict(for: summary.name,
                                               existingSlugs: existingSlugs,
                                               libraryRoot: libraryRoot)

        if resolved.name != summary.name {
            let updated = try SkillFrontMatterRewriter.rewriteName(in: skillData,
                                                                   sourcePath: skillFile.path,
                                                                   newName: resolved.name)
            try updated.write(to: skillFile, atomically: true, encoding: .utf8)
        }

        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let destination = libraryRoot.appendingPathComponent(resolved.slug, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            throw SkillMarketplaceError.invalidSkill("Destination folder already exists: \(resolved.slug)")
        }

        try fileManager.moveItem(at: stagingRoot, to: destination)
        return SkillMarketplaceInstallResult(slug: resolved.slug, destination: destination)
    }

    func installPlugin(_ plugin: SkillMarketplacePlugin,
                       from listing: SkillMarketplaceListing,
                       existingSlugs: Set<String>,
                       libraryRoot: URL = skillsLibraryURL()) async throws -> SkillMarketplaceInstallResult {
        let normalizedSource = try resolvePluginSource(plugin.source,
                                                       pluginRoot: listing.document.metadata?.pluginRoot)

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcp-bundler-marketplace-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = tempRoot.appendingPathComponent("skill", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try await downloadFolder(owner: listing.owner,
                                 repo: listing.repo,
                                 branch: listing.defaultBranch,
                                 path: normalizedSource,
                                 pluginRoot: normalizedSource,
                                 destinationRoot: stagingRoot)

        let skillFile = stagingRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: skillFile.path) else {
            let pluginManifest = stagingRoot
                .appendingPathComponent(".claude-plugin", isDirectory: true)
                .appendingPathComponent("plugin.json", isDirectory: false)
            if fileManager.fileExists(atPath: pluginManifest.path) {
                throw SkillMarketplaceError.invalidSkill("Selected marketplace entry is a Claude plugin, not a skill. MCP Bundler installs SKILL.md skills only.")
            }
            throw SkillMarketplaceError.missingSkillFile
        }

        let skillData = try Data(contentsOf: skillFile)
        let summary = try SkillFrontMatterReader.parse(data: skillData, sourcePath: skillFile.path)
        let resolved = try resolveSlugConflict(for: summary.name,
                                               existingSlugs: existingSlugs,
                                               libraryRoot: libraryRoot)

        if resolved.name != summary.name {
            let updated = try SkillFrontMatterRewriter.rewriteName(in: skillData,
                                                                   sourcePath: skillFile.path,
                                                                   newName: resolved.name)
            try updated.write(to: skillFile, atomically: true, encoding: .utf8)
        }

        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let destination = libraryRoot.appendingPathComponent(resolved.slug, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            throw SkillMarketplaceError.invalidSkill("Destination folder already exists: \(resolved.slug)")
        }

        try fileManager.moveItem(at: stagingRoot, to: destination)
        return SkillMarketplaceInstallResult(slug: resolved.slug, destination: destination)
    }

    @MainActor
    func loadSources(in context: ModelContext) throws -> [SkillMarketplaceSource] {
        let descriptor = FetchDescriptor<SkillMarketplaceSource>()
        let sources = try context.fetch(descriptor)
        return SkillMarketplaceSourceDefaults.sortSources(sources)
    }
}

private extension SkillMarketplaceService {
    struct RepositoryInfo: Decodable {
        let defaultBranch: String

        enum CodingKeys: String, CodingKey {
            case defaultBranch = "default_branch"
        }
    }

    enum ContentType: String, Decodable {
        case file
        case dir
        case symlink
        case submodule
    }

    struct ContentEntry: Decodable {
        let name: String
        let path: String
        let type: ContentType
        let downloadURL: URL?
        let url: URL
        let encoding: String?
        let content: String?
        let sha: String?

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case type
            case downloadURL = "download_url"
            case url
            case encoding
            case content
            case sha
        }
    }

    struct PluginResolution {
        let name: String
        let slug: String
    }

    func fetchRepositoryInfo(owner: String, repo: String) async throws -> RepositoryInfo {
        let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        let data = try await fetchAPIData(from: endpoint)
        return try decoder.decode(RepositoryInfo.self, from: data)
    }

    func fetchMarketplaceDocument(owner: String, repo: String, branch: String) async throws -> SkillMarketplaceDocument {
        let manifest = try await fetchMarketplaceManifest(owner: owner,
                                                          repo: repo,
                                                          branch: branch,
                                                          cachedManifestSHA: nil,
                                                          cachedManifestJSON: nil)
        return manifest.document
    }

    func fetchMarketplaceManifest(owner: String,
                                  repo: String,
                                  branch: String,
                                  cachedManifestSHA: String?,
                                  cachedManifestJSON: String?) async throws -> MarketplaceManifest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/contents/.claude-plugin/marketplace.json"
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        guard let url = components.url else {
            throw SkillMarketplaceError.invalidMarketplaceDocument("Invalid marketplace URL")
        }

        do {
            let data = try await fetchAPIData(from: url)
            let entry: ContentEntry
            do {
                entry = try decoder.decode(ContentEntry.self, from: data)
            } catch {
                throw SkillMarketplaceError.invalidMarketplaceDocument("Marketplace manifest response is invalid")
            }

            guard entry.type == .file else {
                throw SkillMarketplaceError.invalidMarketplaceDocument("Marketplace manifest is not a file")
            }

            if let manifestSHA = entry.sha,
               let cachedManifestSHA,
               manifestSHA == cachedManifestSHA,
               let cachedManifestJSON,
               let cachedData = cachedManifestJSON.data(using: .utf8) {
                let document = try decodeMarketplace(data: cachedData)
                return MarketplaceManifest(document: document,
                                           manifestSHA: manifestSHA,
                                           manifestJSON: cachedManifestJSON)
            }

            if let content = entry.content, entry.encoding == "base64" {
                guard let decoded = Data(base64Encoded: content, options: [.ignoreUnknownCharacters]) else {
                    throw SkillMarketplaceError.invalidMarketplaceDocument("Marketplace manifest base64 decode failed")
                }
                let document = try decodeMarketplace(data: decoded)
                let manifestJSON = String(data: decoded, encoding: .utf8)
                return MarketplaceManifest(document: document,
                                           manifestSHA: entry.sha,
                                           manifestJSON: manifestJSON)
            }

            guard let downloadURL = entry.downloadURL else {
                throw SkillMarketplaceError.invalidMarketplaceDocument("Marketplace manifest download URL missing")
            }
            let rawData = try await fetchRawData(from: downloadURL)
            let document = try decodeMarketplace(data: rawData)
            let manifestJSON = String(data: rawData, encoding: .utf8)
            return MarketplaceManifest(document: document,
                                       manifestSHA: entry.sha,
                                       manifestJSON: manifestJSON)
        } catch let error as SkillMarketplaceError {
            switch error {
            case .apiFailure(let status, _) where status >= 500:
                return try await fetchMarketplaceManifestViaRaw(owner: owner, repo: repo, branch: branch)
            default:
                throw error
            }
        }
    }

    func fetchMarketplaceManifestRawFirst(owner: String,
                                          repo: String,
                                          cachedDefaultBranch: String?) async throws -> (manifest: MarketplaceManifest, branch: String)? {
        var branchCandidates: [String] = []
        if let cachedDefaultBranch, !cachedDefaultBranch.isEmpty {
            branchCandidates.append(cachedDefaultBranch)
        }
        branchCandidates.append(contentsOf: ["main", "master"])
        var seen = Set<String>()
        branchCandidates = branchCandidates.filter { seen.insert($0).inserted }

        var lastError: SkillMarketplaceError?
        for branch in branchCandidates {
            do {
                let manifest = try await fetchMarketplaceManifestViaRaw(owner: owner, repo: repo, branch: branch)
                return (manifest: manifest, branch: branch)
            } catch let error as SkillMarketplaceError {
                if case .apiFailure(let status, _) = error, status == 404 {
                    continue
                }
                lastError = error
                break
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    func resolveListing(owner: String,
                        repo: String,
                        defaultBranch: String,
                        manifest: MarketplaceManifest,
                        cachedManifestSHA: String?,
                        cachedMarketplaceJSON: String?,
                        cachedSkillNames: [String]?) async throws -> SkillMarketplaceFetchResult {
        let cachedNames = cachedSkillNames?.map { $0.lowercased() }
        let skillNames: [String]
        var cacheUpdate: SkillMarketplaceCacheUpdate?

        if let manifestSHA = manifest.manifestSHA,
           manifestSHA == cachedManifestSHA,
           let cachedNames {
            skillNames = cachedNames
        } else if let manifestJSON = manifest.manifestJSON,
                  manifestJSON == cachedMarketplaceJSON,
                  let cachedNames {
            skillNames = cachedNames
        } else {
            skillNames = try await fetchSkillPluginNames(plugins: manifest.document.plugins,
                                                         owner: owner,
                                                         repo: repo,
                                                         branch: defaultBranch,
                                                         pluginRoot: manifest.document.metadata?.pluginRoot)
            if let manifestJSON = manifest.manifestJSON {
                cacheUpdate = SkillMarketplaceCacheUpdate(manifestSHA: manifest.manifestSHA,
                                                          defaultBranch: defaultBranch,
                                                          manifestJSON: manifestJSON,
                                                          skillNames: skillNames)
            }
        }

        let skillSet = Set(skillNames.map { $0.lowercased() })
        let filteredPlugins = manifest.document.plugins.filter { skillSet.contains($0.name.lowercased()) }
        let filteredDocument = SkillMarketplaceDocument(name: manifest.document.name,
                                                        owner: manifest.document.owner,
                                                        metadata: manifest.document.metadata,
                                                        plugins: filteredPlugins)

        let listing = SkillMarketplaceListing(owner: owner,
                                              repo: repo,
                                              defaultBranch: defaultBranch,
                                              document: filteredDocument)
        return SkillMarketplaceFetchResult(listing: listing,
                                           cacheUpdate: cacheUpdate,
                                           warningMessage: nil)
    }

    func decodeMarketplace(data: Data) throws -> SkillMarketplaceDocument {
        do {
            return try decoder.decode(SkillMarketplaceDocument.self, from: data)
        } catch {
            if let missing = missingRequiredFields(in: data), !missing.isEmpty {
                let joined = missing.sorted().joined(separator: ", ")
                throw SkillMarketplaceError.invalidMarketplaceDocument("Missing required fields: \(joined)")
            }
            if let details = describeDecodingError(error) {
                throw SkillMarketplaceError.invalidMarketplaceDocument(details)
            }
            throw SkillMarketplaceError.invalidMarketplaceDocument(error.localizedDescription)
        }
    }

    func normalizePluginSource(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillMarketplaceError.invalidPluginSource("Source path is empty")
        }
        guard !trimmed.hasPrefix("/") else {
            throw SkillMarketplaceError.invalidPluginSource("Source path must be relative")
        }
        guard !trimmed.contains("\\") else {
            throw SkillMarketplaceError.invalidPluginSource("Backslashes are not allowed")
        }

        var value = trimmed
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }

        let parts = value.split(separator: "/").map(String.init)
        let cleaned = parts.filter { $0 != "." }
        guard !cleaned.contains("..") else {
            throw SkillMarketplaceError.invalidPluginSource("Source path cannot include ..")
        }

        let normalized = cleaned.joined(separator: "/")
        guard !normalized.isEmpty else {
            throw SkillMarketplaceError.invalidPluginSource("Source path is empty")
        }

        return normalized
    }

    func downloadFolder(owner: String,
                        repo: String,
                        branch: String,
                        path: String,
                        pluginRoot: String,
                        destinationRoot: URL) async throws {
        let entries = try await fetchContents(owner: owner, repo: repo, branch: branch, path: path)
        for entry in entries {
            let relative = relativePath(for: entry.path, root: pluginRoot)
            guard let relative, !relative.isEmpty else { continue }
            guard !shouldSkip(relativePath: relative) else { continue }

            switch entry.type {
            case .file:
                guard let downloadURL = entry.downloadURL else {
                    throw SkillMarketplaceError.unsupportedContentEntry(entry.path)
                }
                let data = try await fetchRawData(from: downloadURL)
                let destination = try resolve(relativePath: relative, base: destinationRoot)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try data.write(to: destination)

            case .dir:
                try await downloadFolder(owner: owner,
                                         repo: repo,
                                         branch: branch,
                                         path: entry.path,
                                         pluginRoot: pluginRoot,
                                         destinationRoot: destinationRoot)

            case .symlink, .submodule:
                throw SkillMarketplaceError.unsupportedContentEntry(entry.path)
            }
        }
    }

    func fetchContents(owner: String,
                       repo: String,
                       branch: String,
                       path: String) async throws -> [ContentEntry] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/contents/\(path)"
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        guard let url = components.url else {
            throw SkillMarketplaceError.invalidPluginSource("Invalid contents URL")
        }
        let data = try await fetchAPIData(from: url)
        if let entries = try? decoder.decode([ContentEntry].self, from: data) {
            return entries
        }
        let entry = try decoder.decode(ContentEntry.self, from: data)
        if entry.type == .dir {
            return [entry]
        }
        throw SkillMarketplaceError.invalidPluginSource("Source path must be a folder")
    }

    func fetchAPIData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("MCPBundler", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkillMarketplaceError.apiFailure(status: -1, message: "Invalid response")
        }

        if http.statusCode == 403, Self.isRateLimit(response: http) {
            throw SkillMarketplaceError.rateLimited(reset: Self.rateLimitReset(from: http))
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.parseAPIErrorMessage(from: data) ?? "Unexpected response"
            throw SkillMarketplaceError.apiFailure(status: http.statusCode, message: message)
        }

        return data
    }

    func fetchMarketplaceManifestViaRaw(owner: String, repo: String, branch: String) async throws -> MarketplaceManifest {
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/.claude-plugin/marketplace.json")!
        let rawData = try await fetchRawData(from: url)
        let document = try decodeMarketplace(data: rawData)
        let manifestJSON = String(data: rawData, encoding: .utf8)
        return MarketplaceManifest(document: document,
                                   manifestSHA: nil,
                                   manifestJSON: manifestJSON)
    }

    func fetchRawData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("MCPBundler", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkillMarketplaceError.apiFailure(status: -1, message: "Invalid response")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SkillMarketplaceError.apiFailure(status: http.statusCode, message: "Download failed")
        }

        return data
    }

    static func parseAPIErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any],
              let message = dict["message"] as? String else {
            return nil
        }
        return message
    }

    static func isRateLimit(response: HTTPURLResponse) -> Bool {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        return remaining == "0"
    }

    static func rateLimitReset(from response: HTTPURLResponse) -> Date? {
        guard let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let seconds = TimeInterval(reset) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func shouldSkip(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            if component == ".DS_Store" || component == "__MACOSX" || component == ".mcp-bundler" {
                return true
            }
        }
        return false
    }

    func relativePath(for fullPath: String, root: String) -> String? {
        if fullPath == root {
            return ""
        }
        if fullPath.hasPrefix(root + "/") {
            let start = fullPath.index(fullPath.startIndex, offsetBy: root.count + 1)
            return String(fullPath[start...])
        }
        return nil
    }

    func resolve(relativePath: String, base: URL) throws -> URL {
        guard !relativePath.isEmpty else { return base }
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.contains("..") else {
            throw SkillMarketplaceError.invalidPluginSource("Invalid relative path")
        }

        var url = base
        for part in parts {
            url.appendPathComponent(part, isDirectory: false)
        }

        let standardized = url.standardizedFileURL
        let basePath = base.standardizedFileURL.path
        guard standardized.path.hasPrefix(basePath) else {
            throw SkillMarketplaceError.invalidPluginSource("Invalid relative path")
        }

        return standardized
    }

    func resolveSlugConflict(for name: String,
                             existingSlugs: Set<String>,
                             libraryRoot: URL) throws -> PluginResolution {
        let baseSlug = try SkillSlugifier.slug(from: name, sourcePath: "SKILL.md")
        var attempt = 0
        var candidateName = name
        var candidateSlug = baseSlug

        while slugExists(candidateSlug, existingSlugs: existingSlugs, libraryRoot: libraryRoot) {
            attempt += 1
            if attempt == 1 {
                candidateName = "\(name) Copy"
            } else {
                candidateName = "\(name) Copy \(attempt)"
            }
            candidateSlug = try SkillSlugifier.slug(from: candidateName, sourcePath: "SKILL.md")
        }

        return PluginResolution(name: candidateName, slug: candidateSlug)
    }

    func slugExists(_ slug: String, existingSlugs: Set<String>, libraryRoot: URL) -> Bool {
        if existingSlugs.contains(slug.lowercased()) {
            return true
        }
        let path = libraryRoot.appendingPathComponent(slug, isDirectory: true).path
        return fileManager.fileExists(atPath: path)
    }

    func resolvePluginSource(_ source: SkillMarketplacePluginSource, pluginRoot: String?) throws -> String {
        switch source {
        case .path(let raw):
            var resolved = raw
            if let pluginRoot, !pluginRoot.isEmpty {
                let trimmedRoot = pluginRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedRoot.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("./"), !raw.hasPrefix("../") {
                    resolved = "\(trimmedRoot)/\(raw)"
                }
            }
            return try normalizePluginSource(resolved)
        case .github:
            throw SkillMarketplaceError.invalidPluginSource("GitHub plugin sources are not supported yet.")
        case .url:
            throw SkillMarketplaceError.invalidPluginSource("URL plugin sources are not supported yet.")
        case .unknown(let source):
            throw SkillMarketplaceError.invalidPluginSource("Unsupported plugin source type: \(source)")
        }
    }

    func fetchSkillPluginNames(plugins: [SkillMarketplacePlugin],
                               owner: String,
                               repo: String,
                               branch: String,
                               pluginRoot: String?) async throws -> [String] {
        let indexed = Array(plugins.enumerated())
        var resolvedPaths: [(Int, String)] = []
        resolvedPaths.reserveCapacity(plugins.count)

        for (index, plugin) in indexed {
            if let path = try resolvePluginSourceForSkillCheck(plugin.source, pluginRoot: pluginRoot) {
                resolvedPaths.append((index, path))
            }
        }

        var results = Array(repeating: false, count: plugins.count)
        let chunkSize = 8
        let session = session

        for start in stride(from: 0, to: resolvedPaths.count, by: chunkSize) {
            let end = min(start + chunkSize, resolvedPaths.count)
            let chunk = resolvedPaths[start..<end]

            try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
                for (index, path) in chunk {
                    group.addTask {
                        let hasSkill = try await SkillMarketplaceService.rawSkillFileExists(session: session,
                                                                                            owner: owner,
                                                                                            repo: repo,
                                                                                            branch: branch,
                                                                                            path: path)
                        return (index, hasSkill)
                    }
                }

                for try await (index, hasSkill) in group {
                    results[index] = hasSkill
                }
            }
        }

        var filteredNames: [String] = []
        filteredNames.reserveCapacity(plugins.count)
        for (index, plugin) in indexed where results[index] {
            filteredNames.append(plugin.name.lowercased())
        }
        return filteredNames
    }

    func resolvePluginSourceForSkillCheck(_ source: SkillMarketplacePluginSource,
                                          pluginRoot: String?) throws -> String? {
        switch source {
        case .path(let raw):
            var resolved = raw
            if let pluginRoot, !pluginRoot.isEmpty {
                let trimmedRoot = pluginRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedRoot.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("./"), !raw.hasPrefix("../") {
                    resolved = "\(trimmedRoot)/\(raw)"
                }
            }
            return try normalizePluginSource(resolved)
        case .github, .url, .unknown:
            return nil
        }
    }

    static func rawSkillFileExists(session: URLSession,
                                   owner: String,
                                   repo: String,
                                   branch: String,
                                   path: String) async throws -> Bool {
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)/SKILL.md")!
        var request = URLRequest(url: url)
        request.setValue("MCPBundler", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkillMarketplaceError.apiFailure(status: -1, message: "Invalid response")
        }

        if http.statusCode == 404 {
            return false
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SkillMarketplaceError.apiFailure(status: http.statusCode, message: "Download failed")
        }

        return true
    }

    func cachedListing(owner: String,
                       repo: String,
                       defaultBranch: String,
                       marketplaceJSON: String,
                       skillNames: [String]) throws -> SkillMarketplaceListing {
        guard let data = marketplaceJSON.data(using: .utf8) else {
            throw SkillMarketplaceError.invalidMarketplaceDocument("Cached marketplace JSON is invalid")
        }
        let document = try decodeMarketplace(data: data)
        let skillSet = Set(skillNames.map { $0.lowercased() })
        let filteredPlugins = document.plugins.filter { skillSet.contains($0.name.lowercased()) }
        let filteredDocument = SkillMarketplaceDocument(name: document.name,
                                                        owner: document.owner,
                                                        metadata: document.metadata,
                                                        plugins: filteredPlugins)
        return SkillMarketplaceListing(owner: owner,
                                       repo: repo,
                                       defaultBranch: defaultBranch,
                                       document: filteredDocument)
    }

    func missingRequiredFields(in data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any] else {
            return nil
        }

        func isMissing(_ value: Any?) -> Bool {
            if value == nil { return true }
            return value is NSNull
        }

        var missing: [String] = []
        let requiredKeys = ["name", "owner", "plugins"]
        for key in requiredKeys {
            if isMissing(root[key]) {
                missing.append(key)
            }
        }

        if let owner = root["owner"] as? [String: Any] {
            if isMissing(owner["name"]) { missing.append("owner.name") }
        } else if root["owner"] != nil {
            missing.append("owner.name")
        }

        if let plugins = root["plugins"] {
            if plugins is NSNull {
                missing.append("plugins")
            } else if !(plugins is [Any]) {
                missing.append("plugins")
            }
        }

        return missing
    }

    func describeDecodingError(_ error: Error) -> String? {
        guard let decoding = error as? DecodingError else { return nil }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "Missing required field '\(key.stringValue)' at \(codingPathDescription(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "Field type mismatch (\(type)) at \(codingPathDescription(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "Missing value (\(type)) at \(codingPathDescription(context.codingPath))"
        case .dataCorrupted(let context):
            return "Data corrupted at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return nil
        }
    }

    func codingPathDescription(_ path: [CodingKey]) -> String {
        let value = path.map { $0.stringValue }.joined(separator: ".")
        return value.isEmpty ? "root" : value
    }
}

private struct MarketplaceManifest {
    let document: SkillMarketplaceDocument
    let manifestSHA: String?
    let manifestJSON: String?
}

enum SkillFrontMatterRewriter {
    static func rewriteName(in data: Data, sourcePath: String, newName: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw SkillMarketplaceError.invalidSkill("SKILL.md at \(sourcePath) is not valid UTF-8/UTF-16 text")
        }
        return try rewriteName(in: text, sourcePath: sourcePath, newName: newName)
    }

    static func rewriteName(in text: String, sourcePath: String, newName: String) throws -> String {
        let sanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = sanitized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            throw SkillMarketplaceError.invalidSkill("SKILL.md missing YAML front matter opening delimiter '---'")
        }

        var endIndex: Int?
        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }
        }
        guard let frontMatterEnd = endIndex else {
            throw SkillMarketplaceError.invalidSkill("SKILL.md missing YAML front matter closing delimiter '---'")
        }

        let frontMatter = Array(lines[1..<frontMatterEnd])
        var updated: [String] = []
        var index = 0
        var didUpdate = false

        while index < frontMatter.count {
            let line = frontMatter[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                updated.append(line)
                index += 1
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                updated.append(line)
                index += 1
                continue
            }

            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

            if key == "name" {
                updated.append("name: \(newName)")
                didUpdate = true

                if value == "|" || value == "|-" || value == ">" || value == ">-" || value.isEmpty {
                    let indent = indentationLevel(of: line) + 2
                    index += 1
                    while index < frontMatter.count {
                        let nextLine = frontMatter[index]
                        if nextLine.trimmingCharacters(in: .whitespaces).isEmpty {
                            index += 1
                            continue
                        }
                        let nextIndent = indentationLevel(of: nextLine)
                        if nextIndent >= indent {
                            index += 1
                            continue
                        }
                        break
                    }
                } else {
                    index += 1
                }

                continue
            }

            updated.append(line)
            index += 1
        }

        guard didUpdate else {
            throw SkillMarketplaceError.invalidSkill("Front matter missing 'name' at \(sourcePath)")
        }

        var rebuilt: [String] = []
        rebuilt.append("---")
        rebuilt.append(contentsOf: updated)
        rebuilt.append("---")
        if frontMatterEnd + 1 < lines.count {
            rebuilt.append(contentsOf: lines[(frontMatterEnd + 1)...])
        }

        return rebuilt.joined(separator: "\n")
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

private enum SkillSlugifier {
    static func slug(from name: String, sourcePath: String) throws -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        var slug = String(mapped)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else {
            throw SkillMarketplaceError.invalidSkill("Skill name produces empty slug at \(sourcePath)")
        }
        return slug
    }
}
