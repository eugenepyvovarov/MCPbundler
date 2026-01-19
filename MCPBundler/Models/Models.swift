//
//  Models.swift
//  MCP Bundler
//
//  Data model for Projects, Servers, Env/Headers, Capability Cache, and Logs.
//

import Foundation
import SwiftData

// MARK: - Enums

enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case local_stdio
    case remote_http_sse
    var id: String { rawValue }
}

enum RemoteHTTPMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case httpOnly
    case httpWithSSE
    var id: String { rawValue }
}

enum SecretSource: String, Codable, CaseIterable, Identifiable {
    case plain
    case keychainRef
    case oauthAccessToken
    var id: String { rawValue }
}

enum HealthStatus: String, Codable, CaseIterable, Identifiable {
    case unknown
    case healthy
    case degraded
    case unhealthy
    var id: String { rawValue }
}

enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case error
    case info
    case debug
    var id: String { rawValue }
}

enum OAuthStatus: String, Codable, CaseIterable, Identifiable {
    case unauthorized
    case authorized
    case refreshing
    case error
    var id: String { rawValue }
}

enum OAuthClientSource: String, Codable, CaseIterable, Identifiable {
    case manual
    case dynamic
    var id: String { rawValue }
}

@Model
final class BundlerEvent {
    enum EventType: String, Codable {
        case snapshotRebuilt
        case serverAdded
        case serverUpdated
        case serverRemoved
        case serverDisabled
        case serverEnabled
    }

    var id: UUID
    var projectToken: UUID
    var serverTokens: [UUID]
    var type: EventType
    var createdAt: Date
    var handled: Bool

    init(id: UUID = UUID(),
         projectToken: UUID,
         serverTokens: [UUID] = [],
         type: EventType,
         createdAt: Date = Date(),
         handled: Bool = false) {
        self.id = id
        self.projectToken = projectToken
        self.serverTokens = serverTokens
        self.type = type
        self.createdAt = createdAt
        self.handled = handled
    }
}

// MARK: - Models

@Model
final class ProviderFolder {
    @Relationship var project: Project?
    var name: String
    var isEnabled: Bool
    var isCollapsed: Bool
    var createdAt: Date
    var updatedAt: Date

    init(project: Project? = nil,
         name: String,
         isEnabled: Bool = true,
         isCollapsed: Bool = false) {
        self.project = project
        self.name = name
        self.isEnabled = isEnabled
        self.isCollapsed = isCollapsed
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

extension ProviderFolder {
    var stableID: PersistentIdentifier { persistentModelID }
}

@Model
final class Project {
    private static let fallbackName = "Untitled Project"

    var name: String
    var details: String?
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date
    static let defaultLargeToolResponseThreshold = 5_000

    var eventToken: UUID = UUID()
    var contextOptimizationsEnabled: Bool = false {
        didSet {
            guard contextOptimizationsEnabled != oldValue else { return }
            markUpdated()
        }
    }
    var hideSkillsForNativeClients: Bool = false {
        didSet {
            guard hideSkillsForNativeClients != oldValue else { return }
            markUpdated()
        }
    }
    var showOtherLocationsToggle: Bool = true {
        didSet {
            guard showOtherLocationsToggle != oldValue else { return }
            markUpdated()
        }
    }
    @Attribute var storeLargeToolResponsesAsFiles: Bool = false
    @Attribute var largeToolResponseThreshold: Int = Project.defaultLargeToolResponseThreshold {
        didSet {
            if largeToolResponseThreshold < 0 {
                largeToolResponseThreshold = 0
            }
        }
    }

    @Relationship(deleteRule: .cascade) var folders: [ProviderFolder]
    @Relationship(deleteRule: .cascade) var servers: [Server]
    @Relationship(deleteRule: .cascade) var envVars: [EnvVar]
    @Relationship(deleteRule: .cascade) var logs: [LogEntry]
    var cachedSnapshot: Data?
    var cachedSnapshotVersion: Int?
    var cachedSnapshotGeneratedAt: Date?
    var snapshotRevision: Int64 = 0

    init(name: String, details: String? = nil, isActive: Bool = false) {
        self.name = Self.normalizeName(name)
        self.details = Self.normalizeDetails(details)
        self.isActive = isActive
        self.createdAt = Date()
        self.updatedAt = Date()
        self.folders = []
        self.servers = []
        self.envVars = []
        self.logs = []
        self.cachedSnapshot = nil
        self.cachedSnapshotVersion = nil
        self.cachedSnapshotGeneratedAt = nil
        self.snapshotRevision = 0
    }

    func rename(to newName: String) {
        let normalized = Self.normalizeName(newName)
        guard normalized != name else { return }
        name = normalized
        markUpdated()
    }

    func updateDetails(_ newDetails: String?) {
        let normalized = Self.normalizeDetails(newDetails)
        guard normalized != details else { return }
        details = normalized
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }

    @MainActor
    var sortedServers: [Server] {
        servers.sorted { lhs, rhs in
            lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }
    }

    private static func normalizeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackName : trimmed
    }

    private static func normalizeDetails(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@Model
final class Server {
    var project: Project?
    var alias: String
    var kind: ServerKind
    var eventToken: UUID = UUID()
    @Relationship var folder: ProviderFolder?

    // Local STDIO
    var execPath: String?
    @Attribute
    private var argsStorage: Data?
    var args: [String] {
        get { Self.decodeStringArray(from: argsStorage) }
        set { argsStorage = newValue.isEmpty ? nil : Self.encodeStringArray(newValue) }
    }
    var cwd: String?
    @Relationship(deleteRule: .cascade) var envOverrides: [EnvVar]

    // Remote HTTP/SSE
    var baseURL: String?
    @Relationship(deleteRule: .cascade) var headers: [HeaderBinding]
    @Relationship(deleteRule: .cascade) var oauthConfiguration: OAuthConfiguration?
    @Relationship(deleteRule: .cascade) var oauthState: OAuthState?
    @Attribute private var oauthStatusStorage: String = OAuthStatus.unauthorized.rawValue
    @Attribute private var oauthDiagnosticsStorage: Data?
    var isOAuthDebugLoggingEnabled: Bool = false
    @Attribute private var remoteHTTPModeStorage: String = RemoteHTTPMode.auto.rawValue

    var oauthStatus: OAuthStatus {
        get { OAuthStatus(rawValue: oauthStatusStorage) ?? .unauthorized }
        set { oauthStatusStorage = newValue.rawValue }
    }

    var oauthDiagnostics: OAuthDiagnosticsLog {
        get {
            guard let data = oauthDiagnosticsStorage,
                  let log = try? JSONDecoder().decode(OAuthDiagnosticsLog.self, from: data) else {
                return OAuthDiagnosticsLog()
            }
            return log
        }
        set {
            oauthDiagnosticsStorage = try? JSONEncoder().encode(newValue)
        }
    }

    var remoteHTTPMode: RemoteHTTPMode {
        get { RemoteHTTPMode(rawValue: remoteHTTPModeStorage) ?? .auto }
        set { remoteHTTPModeStorage = newValue.rawValue }
    }

    // Exposure controls
    @Attribute
    private var includeToolsStorage: Data?
    var includeTools: [String] {
        get { Self.decodeStringArray(from: includeToolsStorage) }
        set { includeToolsStorage = newValue.isEmpty ? nil : Self.encodeStringArray(newValue) }
    }
    var isEnabled: Bool = true

    // Health / capability cache metadata
    var lastHealth: HealthStatus
    var lastCheckedAt: Date?
    var serverIdentity: String?
    @Relationship(deleteRule: .cascade) var capabilityCaches: [CapabilityCache]

    init(project: Project? = nil, alias: String, kind: ServerKind) {
        self.project = project
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.execPath = nil
        self.argsStorage = nil
        self.cwd = nil
        self.envOverrides = []
        self.baseURL = nil
        self.headers = []
        self.oauthConfiguration = nil
        self.oauthState = nil
        self.oauthStatusStorage = OAuthStatus.unauthorized.rawValue
        self.isOAuthDebugLoggingEnabled = false
        self.remoteHTTPModeStorage = RemoteHTTPMode.auto.rawValue
        self.includeToolsStorage = nil
        self.lastHealth = .unknown
        self.lastCheckedAt = nil
        self.serverIdentity = nil
        self.capabilityCaches = []
        self.folder = nil
    }

    private static func encodeStringArray(_ strings: [String]) -> Data? {
        try? JSONEncoder().encode(strings)
    }

    private static func decodeStringArray(from data: Data?) -> [String] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

@Model
final class EnvVar {
    var project: Project?
    var server: Server?
    var key: String
    var valueSource: SecretSource
    var plainValue: String?
    var keychainRef: String?
    @Attribute private var positionStorage: Int64?
    var position: Int64 {
        get { positionStorage ?? 0 }
        set { positionStorage = newValue }
    }

    init(project: Project? = nil,
         server: Server? = nil,
         key: String,
         valueSource: SecretSource = .plain,
         plainValue: String? = nil,
         keychainRef: String? = nil,
         position: Int64 = 0) {
        self.project = project
        self.server = server
        self.key = key
        self.valueSource = valueSource
        self.plainValue = plainValue
        self.keychainRef = keychainRef
        self.positionStorage = position
    }
}

@Model
final class HeaderBinding {
    var server: Server?
    var header: String
    var valueSource: SecretSource
    var plainValue: String?
    var keychainRef: String?

    static let manualCredentialMarker = "manual-credential"

    init(server: Server? = nil, header: String, valueSource: SecretSource = .plain, plainValue: String? = nil, keychainRef: String? = nil) {
        self.server = server
        self.header = header
        self.valueSource = valueSource
        self.plainValue = plainValue
        self.keychainRef = keychainRef
    }
}

@Model
final class OAuthConfiguration {
    static let defaultMetadataVersion = OAuthConstants.mcpProtocolVersion

    @Relationship(inverse: \Server.oauthConfiguration) var server: Server?
    var authorizationEndpoint: URL?
    var tokenEndpoint: URL?
    var registrationEndpoint: URL?
    var jwksEndpoint: URL?
    @Attribute private var scopesStorage: Data?
    var clientId: String?
    var clientSecret: String?
    var usePKCE: Bool
    var resourceURI: URL?
    var discoveredAt: Date
    var metadataVersion: String
    var clientSource: OAuthClientSource

    init(server: Server? = nil,
         authorizationEndpoint: URL? = nil,
         tokenEndpoint: URL? = nil,
         registrationEndpoint: URL? = nil,
         jwksEndpoint: URL? = nil,
         scopes: [String] = [],
         clientId: String? = nil,
         clientSecret: String? = nil,
         usePKCE: Bool = true,
         resourceURI: URL? = nil,
         discoveredAt: Date = Date(),
         metadataVersion: String = OAuthConfiguration.defaultMetadataVersion,
         clientSource: OAuthClientSource = .dynamic) {
        self.server = server
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.jwksEndpoint = jwksEndpoint
        self.scopesStorage = Self.encodeScopes(scopes)
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.usePKCE = usePKCE
        self.resourceURI = resourceURI
        self.discoveredAt = discoveredAt
        self.metadataVersion = metadataVersion
        self.clientSource = clientSource
    }

    var scopes: [String] {
        get { Self.decodeScopes(from: scopesStorage) }
        set { scopesStorage = Self.encodeScopes(newValue) }
    }

    private static func encodeScopes(_ scopes: [String]) -> Data? {
        guard !scopes.isEmpty else { return nil }
        return try? JSONEncoder().encode(scopes)
    }

    private static func decodeScopes(from data: Data?) -> [String] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}


struct OAuthDiscoveryAttempt: Codable, Identifiable {
    var id: UUID = UUID()
    var url: URL
    var httpMethod: String?
    var requestHeaders: [String: String]?
    var requestBodyPreview: String?
    var responseHeaders: [String: String]?
    var statusCode: Int?
    var message: String?
    var responseBodyPreview: String?
    var timestamp: Date = Date()
}

struct OAuthDiagnosticsLog: Codable {
    var discoveryAttempts: [OAuthDiscoveryAttempt] = []
    var lastErrorDescription: String?
    var lastRefreshFailedAt: Date?

    mutating func recordAttempt(url: URL,
                                httpMethod: String?,
                                requestHeaders: [String: String]?,
                                requestBodyPreview: String?,
                                responseHeaders: [String: String]?,
                                statusCode: Int?,
                                message: String?,
                                responseBodyPreview: String?) {
        discoveryAttempts.append(
            OAuthDiscoveryAttempt(url: url,
                                  httpMethod: httpMethod,
                                  requestHeaders: requestHeaders,
                                  requestBodyPreview: requestBodyPreview,
                                  responseHeaders: responseHeaders,
                                  statusCode: statusCode,
                                  message: message,
                                  responseBodyPreview: responseBodyPreview)
        )
    }
}


@Model
final class OAuthState {
    @Relationship(inverse: \Server.oauthState) var server: Server?
    var serializedAuthState: Data
    var lastTokenRefresh: Date?
    var isActive: Bool
    var keychainItemName: String?
    @Attribute var cloudId: String?
    @Attribute private var providerMetadataStorage: Data?

    init(server: Server? = nil,
         serializedAuthState: Data = Data(),
         lastTokenRefresh: Date? = nil,
         isActive: Bool = false,
         keychainItemName: String? = nil,
         cloudId: String? = nil,
         providerMetadata: [String: String] = [:]) {
        self.server = server
        self.serializedAuthState = serializedAuthState
        self.lastTokenRefresh = lastTokenRefresh
        self.isActive = isActive
        self.keychainItemName = keychainItemName
        self.cloudId = cloudId
        self.providerMetadataStorage = Self.encodeProviderMetadata(providerMetadata)
    }

    var providerMetadata: [String: String] {
        get { Self.decodeProviderMetadata(from: providerMetadataStorage) }
        set { providerMetadataStorage = Self.encodeProviderMetadata(newValue) }
    }

    private static func encodeProviderMetadata(_ metadata: [String: String]) -> Data? {
        guard !metadata.isEmpty else { return nil }
        return try? JSONEncoder().encode(metadata)
    }

    private static func decodeProviderMetadata(from data: Data?) -> [String: String] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

extension Server {
    var usesOAuthAuthorization: Bool {
        headers.contains { $0.valueSource == .oauthAccessToken }
    }

    var usesManualCredentials: Bool {
        headers.contains { header in
            if header.keychainRef == HeaderBinding.manualCredentialMarker { return true }
            guard header.valueSource == .plain else { return false }
            let normalized = header.header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "authorization" || normalized == "x-api-key" { return true }
            return false
        }
    }
}

extension Server {
    var isEffectivelyEnabled: Bool {
        guard isEnabled else { return false }
        if let folder {
            return folder.isEnabled
        }
        return true
    }
}

@Model
final class CapabilityCache {
    var server: Server?
    var payload: Data
    var generatedAt: Date

    init(server: Server? = nil, payload: Data, generatedAt: Date = Date()) {
        self.server = server
        self.payload = payload
        self.generatedAt = generatedAt
    }
}

extension Server {
    @MainActor
    var latestDecodedCapabilities: MCPCapabilities? {
        guard let latest = capabilityCaches.max(by: { $0.generatedAt < $1.generatedAt }) else { return nil }
        return CapabilityDecoderCache.capabilities(for: latest)
    }

    @MainActor
    func replaceCapabilityCache(payload: Data, generatedAt: Date = Date(), in context: ModelContext?) {
        clearCapabilityCaches(in: context)
        let cache = CapabilityCache(server: self, payload: payload, generatedAt: generatedAt)
        capabilityCaches.append(cache)
    }

    @MainActor
    @discardableResult
    func pruneCapabilityCaches(keepingLatestIn context: ModelContext?) -> CapabilityCache? {
        let sorted = capabilityCaches.sorted { $0.generatedAt > $1.generatedAt }
        guard let latest = sorted.first else { return nil }
        let toDelete = Array(sorted.dropFirst())
        guard !toDelete.isEmpty else { return latest }
        capabilityCaches = [latest]
        for cache in toDelete {
            context?.delete(cache)
        }
        return latest
    }

    @MainActor
    func clearCapabilityCaches(in context: ModelContext?) {
        let toDelete = capabilityCaches
        capabilityCaches.removeAll()
        for cache in toDelete {
            context?.delete(cache)
        }
    }
}

@MainActor
private enum CapabilityDecoderCache {
    private struct Entry {
        let generatedAt: Date
        let capabilities: MCPCapabilities
    }

    private static let decoder = JSONDecoder()
    private static var entries: [PersistentIdentifier: Entry] = [:]

    static func capabilities(for cache: CapabilityCache) -> MCPCapabilities? {
        let identifier = cache.persistentModelID

        if let entry = entries[identifier], entry.generatedAt == cache.generatedAt {
            return entry.capabilities
        }

        guard let decoded = try? decoder.decode(MCPCapabilities.self, from: cache.payload) else {
            entries.removeValue(forKey: identifier)
            return nil
        }

        entries[identifier] = Entry(generatedAt: cache.generatedAt, capabilities: decoded)
        return decoded
    }
}

@Model
final class LogEntry {
    var project: Project?
    var timestamp: Date
    var level: LogLevel
    var category: String
    var message: String
    var metadata: Data?

    init(project: Project? = nil, timestamp: Date = Date(), level: LogLevel = .info, category: String, message: String, metadata: Data? = nil) {
        self.project = project
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

// MARK: - Legacy access models (migration only)

@Model
final class LicenseRecord {
    var key: String
    var licenseID: String?
    var activationID: String?
    var status: String
    var statusMessage: String?
    var lastValidatedAt: Date?
    var payload: Data?
    var fingerprint: String?

    init(
        key: String,
        licenseID: String? = nil,
        activationID: String? = nil,
        fingerprint: String? = nil,
        status: String,
        statusMessage: String? = nil,
        lastValidatedAt: Date? = nil,
        payload: Data? = nil
    ) {
        self.key = key
        self.licenseID = licenseID
        self.activationID = activationID
        self.fingerprint = fingerprint
        self.status = status
        self.statusMessage = statusMessage
        self.lastValidatedAt = lastValidatedAt
        self.payload = payload
    }
}

@Model
final class WalletAccessRecord {
    var walletPublicKey: String?
    var refreshToken: String?
    var assertionToken: String?
    var assertionExpiresAt: Date?
    var lastVerifiedAt: Date?
    var balanceRaw: String?
    var decimals: Int
    var requiredRaw: String?
    var statusMessage: String?
    var deviceID: String

    init(walletPublicKey: String? = nil,
         refreshToken: String? = nil,
         assertionToken: String? = nil,
         assertionExpiresAt: Date? = nil,
         lastVerifiedAt: Date? = nil,
         balanceRaw: String? = nil,
         decimals: Int = 0,
         requiredRaw: String? = nil,
         statusMessage: String? = nil,
         deviceID: String) {
        self.walletPublicKey = walletPublicKey
        self.refreshToken = refreshToken
        self.assertionToken = assertionToken
        self.assertionExpiresAt = assertionExpiresAt
        self.lastVerifiedAt = lastVerifiedAt
        self.balanceRaw = balanceRaw
        self.decimals = decimals
        self.requiredRaw = requiredRaw
        self.statusMessage = statusMessage
        self.deviceID = deviceID
    }
}

// MARK: - SwiftData schema versioning

enum MCPBundlerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            Project.self,
            Server.self,
            ProviderFolder.self,
            EnvVar.self,
            HeaderBinding.self,
            OAuthConfiguration.self,
            OAuthState.self,
            CapabilityCache.self,
            LogEntry.self,
            BundlerEvent.self,
            LicenseRecord.self,
            WalletAccessRecord.self,
            SkillFolder.self,
            SkillRecord.self,
            SkillMarketplaceSource.self,
            SkillSyncLocation.self,
            SkillLocationEnablement.self,
            ProjectSkillSelection.self
        ]
    }
}

enum MCPBundlerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            Project.self,
            Server.self,
            ProviderFolder.self,
            EnvVar.self,
            HeaderBinding.self,
            OAuthConfiguration.self,
            OAuthState.self,
            CapabilityCache.self,
            LogEntry.self,
            BundlerEvent.self,
            SkillFolder.self,
            SkillRecord.self,
            SkillMarketplaceSource.self,
            SkillSyncLocation.self,
            SkillLocationEnablement.self,
            ProjectSkillSelection.self
        ]
    }
}

enum MCPBundlerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MCPBundlerSchemaV1.self, MCPBundlerSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .custom(fromVersion: MCPBundlerSchemaV1.self,
                    toVersion: MCPBundlerSchemaV2.self,
                    willMigrate: { context in
                        try purgeLegacyAccessRecords(in: context)
                    },
                    didMigrate: nil)
        ]
    }

    private static func purgeLegacyAccessRecords(in context: ModelContext) throws {
        let licenseRecords = try context.fetch(FetchDescriptor<LicenseRecord>())
        for record in licenseRecords {
            context.delete(record)
        }

        let walletRecords = try context.fetch(FetchDescriptor<WalletAccessRecord>())
        for record in walletRecords {
            context.delete(record)
        }

        try context.save()
    }
}

// MARK: - EnvVar ordering helpers

extension Array where Element == EnvVar {
    func nextEnvPosition() -> Int64 {
        let maxPosition = self.map(\.position).max() ?? 0
        return maxPosition + 1
    }

    func normalizeEnvPositions(startingAt start: Int64 = 1) {
        for (offset, env) in self.enumerated() {
            let desired = start + Int64(offset)
            if env.position != desired {
                env.position = desired
            }
        }
    }
}
