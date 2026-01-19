import Foundation
import CryptoKit
import Combine
import os.log

struct InstallLinkPresentation: Identifiable {
    let id = UUID()
    let projectToken: UUID
    let description: String
    let parseResult: ImportParseResult
}

@MainActor
final class InstallLinkCoordinator: ObservableObject {
    @Published private(set) var pendingPresentation: InstallLinkPresentation?

    func enqueue(_ presentation: InstallLinkPresentation) {
        pendingPresentation = presentation
    }

    func consumePresentation(matching token: UUID) -> InstallLinkPresentation? {
        guard let presentation = pendingPresentation,
              presentation.projectToken == token else {
            return nil
        }
        pendingPresentation = nil
        return presentation
    }
}

enum InstallLinkServiceError: LocalizedError, Identifiable, Equatable {
    case payloadTooLarge
    case base64DecodeFailed
    case jsonMalformed
    case nameMismatch(expected: String)
    case missingServers
    case missingCommand(alias: String)
    case missingURL(alias: String)
    case invalidParams(alias: String)
    case invalidURL(alias: String)
    case noProjects
    case unsupportedLink(String)

    var id: String {
        switch self {
        case .payloadTooLarge: return "payloadTooLarge"
        case .base64DecodeFailed: return "base64DecodeFailed"
        case .jsonMalformed: return "jsonMalformed"
        case .nameMismatch(let name): return "nameMismatch-\(name)"
        case .missingServers: return "missingServers"
        case .missingCommand(let alias): return "missingCommand-\(alias)"
        case .missingURL(let alias): return "missingURL-\(alias)"
        case .invalidParams(let alias): return "invalidParams-\(alias)"
        case .invalidURL(let alias): return "invalidURL-\(alias)"
        case .noProjects: return "noProjects"
        case .unsupportedLink(let description): return "unsupportedLink-\(description)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            return "Install link payload exceeds the 128 KB limit."
        case .base64DecodeFailed:
            return "Unable to decode install link payload. Make sure the config parameter uses URL-safe base64."
        case .jsonMalformed:
            return "Install link payload is not valid JSON."
        case .nameMismatch(let expected):
            return "Install link payload does not contain an entry for \"\(expected)\"."
        case .missingServers:
            return "Bundle payload must include a \"servers\" object."
        case .missingCommand(let alias):
            return "Server \"\(alias)\" is missing the required \"command\" field."
        case .missingURL(let alias):
            return "Server \"\(alias)\" is missing the required \"url\" field."
        case .invalidParams(let alias):
            return "Server \"\(alias)\" has invalid query parameters. Use simple key/value pairs."
        case .invalidURL(let alias):
            return "Server \"\(alias)\" contains an invalid URL."
        case .noProjects:
            return "Create a project before installing servers."
        case .unsupportedLink(let description):
            return description
        }
    }
}

struct InstallLinkService {
    private let logger = Logger(subsystem: "app.mcpbundler.deeplink", category: "InstallLinkService")
    private let maxPayloadBytes = 128 * 1024

    func parse(request: InstallLinkRequest) throws -> ImportParseResult {
        logger.log("deeplink.install.received name=\(request.name, privacy: .public) kind=\(request.kind.rawValue, privacy: .public)")
        guard let data = Data(base64URLEncoded: request.base64Config) else {
            logger.error("deeplink.install.failed reason=base64Decode")
            throw InstallLinkServiceError.base64DecodeFailed
        }
        guard data.count <= maxPayloadBytes else {
            logger.error("deeplink.install.failed reason=payloadTooLarge size=\(data.count, privacy: .public)")
            throw InstallLinkServiceError.payloadTooLarge
        }

        let payloadHash = SHA256.hash(data: data)
        let hashString = payloadHash.compactMap { String(format: "%02x", $0) }.joined()

        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let root = jsonObject as? [String: Any], !root.isEmpty else {
            logger.error("deeplink.install.failed reason=jsonMalformed hash=\(hashString, privacy: .public)")
            throw InstallLinkServiceError.jsonMalformed
        }

        let decoded: DecodedInstallPayload
        switch request.kind {
        case .server:
            decoded = try decodeServerPayload(name: request.name, root: root)
        case .bundle:
            decoded = try decodeBundlePayload(name: request.name, root: root)
        }

        let candidates = decoded.servers.map { buildCandidate(from: $0) }
        let result = ImportParseResult(sourceDescription: decoded.description,
                                       candidates: candidates,
                                       errors: decoded.warnings)
        logger.log("deeplink.install.validated hash=\(hashString, privacy: .public) servers=\(candidates.count, privacy: .public)")
        return result
    }

    private func decodeServerPayload(name: String,
                                     root: [String: Any]) throws -> DecodedInstallPayload {
        guard root[name] != nil else {
            throw InstallLinkServiceError.nameMismatch(expected: name)
        }
        guard root[name] is [String: Any] else {
            throw InstallLinkServiceError.jsonMalformed
        }
        var warnings: [String] = []
        if root.count > 1 {
            warnings.append("Multiple servers detected; showing bundle view.")
        }
        let entries: [InstallLinkServerEntry] = root.compactMap { key, value in
            guard let dict = value as? [String: Any] else { return nil }
            return InstallLinkServerEntry(alias: key, payload: dict)
        }
        guard !entries.isEmpty else {
            throw InstallLinkServiceError.missingServers
        }
        return DecodedInstallPayload(description: "Install servers from \(name)",
                                     servers: entries,
                                     warnings: warnings)
    }

    private func decodeBundlePayload(name: String,
                                     root: [String: Any]) throws -> DecodedInstallPayload {
        guard let bundle = root[name] as? [String: Any] else {
            throw InstallLinkServiceError.nameMismatch(expected: name)
        }
        guard let rawServers = bundle["servers"] as? [String: Any], !rawServers.isEmpty else {
            throw InstallLinkServiceError.missingServers
        }
        let entries: [InstallLinkServerEntry] = rawServers.compactMap { key, value in
            guard let dict = value as? [String: Any] else { return nil }
            return InstallLinkServerEntry(alias: key, payload: dict)
        }
        guard !entries.isEmpty else {
            throw InstallLinkServiceError.missingServers
        }
        let displayName = (bundle["metadata"] as? [String: Any])?["displayName"] as? String
        let description = displayName.map { "Install \( $0 )" } ?? "Install servers from \(name)"
        return DecodedInstallPayload(description: description,
                                     servers: entries,
                                     warnings: [])
    }

    private func buildCandidate(from entry: InstallLinkServerEntry) -> ImportCandidate {
        var warnings: [String] = []
        let allowedKeys: Set<String> = ["kind", "command", "args", "cwd", "env", "url", "transport", "headers", "params"]
        let unknownKeys = entry.payload.keys.filter { !allowedKeys.contains($0) }
        if !unknownKeys.isEmpty {
            let joined = unknownKeys.sorted().joined(separator: ", ")
            warnings.append("Unknown keys: \(joined)")
        }

        let kindValue = (entry.payload["kind"] as? String)?.lowercased()
        let command = entry.payload["command"] as? String
        let cwd = entry.payload["cwd"] as? String
        let args = Self.parseArgs(entry.payload["args"])
        var envWarnings: [String] = []
        let env = Self.parseDictionary(entry.payload["env"], label: "env", warnings: &envWarnings)
        let headers = Self.parseDictionary(entry.payload["headers"], label: "headers", warnings: &envWarnings)
        let params = Self.parseDictionary(entry.payload["params"], label: "params", warnings: &envWarnings)
        warnings.append(contentsOf: envWarnings)
        let transport = entry.payload["transport"] as? String

        var remoteMode: RemoteHTTPMode?
        if let transport {
            remoteMode = RemoteHTTPMode(rawValue: transport)
            if remoteMode == nil {
                remoteMode = RemoteHTTPMode.allCases.first {
                    $0.rawValue.caseInsensitiveCompare(transport) == .orderedSame
                }
            }
        }

        var urlString = entry.payload["url"] as? String
        if !params.isEmpty {
            if var components = URLComponents(string: urlString ?? "") {
                var queryItems = components.queryItems ?? []
                for (key, value) in params.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }
                components.queryItems = queryItems
                urlString = components.url?.absoluteString
                if urlString == nil {
                    warnings.append("Parameters provided but URL could not be built; check values.")
                }
            } else if urlString != nil {
                warnings.append("Unable to append params to URL; check the base address.")
            } else {
                warnings.append("Params ignored because URL is missing.")
            }
        }

        if let urlString,
           urlString.lowercased().hasPrefix("http://") {
            warnings.append("URL uses insecure http:// scheme.")
        }

        let kind: ServerKind
        if kindValue == "http" {
            kind = .remote_http_sse
        } else if kindValue == "stdio" {
            kind = .local_stdio
        } else if urlString != nil {
            kind = .remote_http_sse
        } else {
            kind = .local_stdio
        }

        if kind == .local_stdio && (command?.isEmpty ?? true) {
            return ImportCandidate(alias: entry.alias,
                                   summary: makeImportSummary(for: nil),
                                   details: [],
                                   envVars: [],
                                   headers: [],
                                   server: nil,
                                   error: "Missing executable command")
        }

        if kind == .remote_http_sse && (urlString?.isEmpty ?? true) {
            return ImportCandidate(alias: entry.alias,
                                   summary: makeImportSummary(for: nil),
                                   details: [],
                                   envVars: [],
                                   headers: [],
                                   server: nil,
                                   error: "Missing base URL")
        }

        let definition = ImportedServerDefinition(alias: entry.alias,
                                                  kind: kind,
                                                  execPath: command,
                                                  args: args,
                                                  cwd: cwd,
                                                  env: env,
                                                  headers: headers,
                                                  baseURL: urlString,
                                                  remoteHTTPMode: remoteMode,
                                                  includeTools: [],
                                                  isEnabled: true)
        var details: [ImportFieldDetail] = []
        if let command {
            details.append(ImportFieldDetail(label: kind == .local_stdio ? "Command" : "Executable", value: command))
        }
        if !args.isEmpty {
            details.append(ImportFieldDetail(label: "Arguments", value: args.joined(separator: " ")))
        }
        if let cwd, !cwd.isEmpty {
            details.append(ImportFieldDetail(label: "Working Directory", value: cwd))
        }
        if let urlString {
            details.append(ImportFieldDetail(label: "URL", value: urlString))
        }
        if !params.isEmpty {
            let summary = params.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            details.append(ImportFieldDetail(label: "Query Params", value: summary))
        }
        if let remoteMode {
            details.append(ImportFieldDetail(label: "Transport", value: remoteMode.rawValue))
        }
        if !warnings.isEmpty {
            details.append(ImportFieldDetail(label: "Warnings", value: warnings.joined(separator: "; ")))
        }

        let summary = makeImportSummary(for: definition)
        let envDetails = env.map { ImportFieldDetail(label: $0.key, value: $0.value) }
        let headerDetails = headers.map { ImportFieldDetail(label: $0.key, value: $0.value) }
        return ImportCandidate(alias: entry.alias,
                               summary: summary,
                               details: details,
                               envVars: envDetails,
                               headers: headerDetails,
                               server: definition,
                               error: nil)
    }

    private static func parseArgs(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let array = value as? [String] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { element in
                if let string = element as? String { return string }
                if let number = element as? NSNumber { return number.stringValue }
                return nil
            }
        }
        if let string = value as? String {
            return string.split(separator: " ").map(String.init)
        }
        return []
    }

    private static func parseDictionary(_ value: Any?,
                                        label: String,
                                        warnings: inout [String]) -> [String: String] {
        guard let value else { return [:] }
        if let dictionary = value as? [String: String] {
            return dictionary
        }
        if let dictionary = value as? [String: Any] {
            var normalized: [String: String] = [:]
            for (key, element) in dictionary {
                if let string = element as? String {
                    normalized[key] = string
                } else if let number = element as? NSNumber {
                    normalized[key] = number.stringValue
                } else if let bool = element as? Bool {
                    normalized[key] = bool ? "true" : "false"
                } else {
                    warnings.append("Ignored non-string \(label) value for key \(key).")
                }
            }
            return normalized
        }
        warnings.append("Ignoring \(label) because the value is not a dictionary.")
        return [:]
    }

    private struct InstallLinkServerEntry {
        let alias: String
        let payload: [String: Any]
    }

    private struct DecodedInstallPayload {
        let description: String
        let servers: [InstallLinkServerEntry]
        let warnings: [String]
    }
}

private extension Data {
    init?(base64URLEncoded input: String) {
        var normalized = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch normalized.count % 4 {
        case 2: normalized.append("==")
        case 3: normalized.append("=")
        case 1: normalized.append("===")
        default: break
        }
        self.init(base64Encoded: normalized)
    }
}
