import Foundation
import SwiftData
import os.log
import MCP

struct ImportClientDescriptor: Identifiable, Hashable {
    let id: String
    let instructionID: String
    let displayName: String
    let configPath: String
    let resolvedURL: URL
    let importFormat: ClientInstallInstruction.ConfigFile.ImportFormat

    var summary: String {
        "\(displayName) (\(configPath))"
    }
}

struct ImportFieldDetail: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
}

struct ImportCandidateSummary: Hashable {
    let transportLabel: String
    let executable: String
    let remoteURL: String
    let arguments: String
    let envSummary: String
    let headerSummary: String
    let enabledSummary: String
}

struct ImportCandidate: Identifiable, Hashable {
    let id = UUID()
    let alias: String
    let summary: ImportCandidateSummary
    let details: [ImportFieldDetail]
    let envVars: [ImportFieldDetail]
    let headers: [ImportFieldDetail]
    let server: ImportedServerDefinition?
    let error: String?
}

extension ImportCandidate {
    var isSelectable: Bool {
        server != nil && error == nil
    }
}

struct ImportParseResult {
    let sourceDescription: String
    let candidates: [ImportCandidate]
    let errors: [String]

    var successCount: Int {
        candidates.filter { $0.server != nil && $0.error == nil }.count
    }

    var failureCount: Int {
        candidates.count - successCount
    }
}

struct ImportedServerDefinition: Hashable {
    var alias: String
    var kind: ServerKind
    var execPath: String?
    var args: [String]
    var cwd: String?
    var env: [String: String]
    var headers: [String: String]
    var baseURL: String?
    var remoteHTTPMode: RemoteHTTPMode? = nil
    var includeTools: [String]
    var isEnabled: Bool
}

struct ImportPersistenceResult {
    let server: Server
    let originalAlias: String
    let appliedAlias: String
}

@MainActor
final class ExternalConfigImporter {
    private let logger = Logger(subsystem: "app.mcpbundler.import", category: "ExternalConfigImporter")

    func parse(client: ImportClientDescriptor) async -> Result<ImportParseResult, Error> {
        do {
            let data = try Data(contentsOf: client.resolvedURL)
            let result = try await parse(data: data,
                                         format: client.importFormat,
                                         description: client.summary)
            return .success(result)
        } catch {
            logger.error("Failed to parse client config: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    func parseManualInput(_ data: Data,
                          formats: [ClientInstallInstruction.ConfigFile.ImportFormat],
                          description: String) async -> Result<ImportParseResult, Error> {
        var bestResult: ImportParseResult?
        for format in formats {
            if let candidate = try? await parse(data: data, format: format, description: description) {
                if bestResult == nil || candidate.successCount > bestResult?.successCount ?? 0 {
                    bestResult = candidate
                }
            }
        }

        if let bestResult, bestResult.successCount > 0 {
            return .success(bestResult)
        }
        return .failure(ImportError.unrecognizedFormat)
    }

    func persist(_ definition: ImportedServerDefinition,
                 originalAlias: String,
                 project: Project,
                 context: ModelContext,
                 stdiosessionController: StdiosessionController?,
                 folder: ProviderFolder? = nil) async throws -> ImportPersistenceResult {
        let alias = makeUniqueAlias(originalAlias, in: project)
        let server = Server(project: project, alias: alias, kind: definition.kind)
        server.execPath = definition.execPath
        server.args = definition.args
        server.cwd = definition.cwd
        server.baseURL = definition.baseURL
        if let mode = definition.remoteHTTPMode {
            server.remoteHTTPMode = mode
        }
        server.includeTools = definition.includeTools
        server.isEnabled = definition.isEnabled
        server.lastHealth = .unknown
        server.lastCheckedAt = nil
        server.serverIdentity = nil

        var position: Int64 = 1
        for (key, value) in definition.env.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let env = EnvVar(server: server,
                             key: key,
                             valueSource: .plain,
                             plainValue: value,
                             position: position)
            server.envOverrides.append(env)
            position += 1
        }

        for (header, value) in definition.headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let binding = HeaderBinding(server: server,
                                        header: header,
                                        valueSource: .plain,
                                        plainValue: value)
            server.headers.append(binding)
        }

        server.folder = folder
        if let folder, folder.isEnabled == false {
            server.isEnabled = false
        }
        context.insert(server)
        if !project.servers.contains(where: { $0 === server }) {
            project.servers.append(server)
        }
        project.markUpdated()

        try context.save()
        Task { @MainActor in
            try? await ProjectSnapshotCache.rebuildSnapshot(for: project)
            BundlerEventService.emit(in: context,
                                     project: project,
                                     servers: [server],
                                     type: .serverAdded)
            let projectID = project.persistentModelID
            let serverID = server.persistentModelID
            await stdiosessionController?.reload(projectID: projectID,
                                                 serverIDs: Set([serverID]))
            if context.hasChanges {
                try? context.save()
            }
        }

        runHealthCheck(for: server)
        return ImportPersistenceResult(server: server,
                                       originalAlias: originalAlias,
                                       appliedAlias: alias)
    }

    private func makeUniqueAlias(_ alias: String, in project: Project) -> String {
        let sanitized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return fallbackAlias(in: project) }
        if !project.servers.contains(where: { $0.alias.compare(sanitized, options: [.caseInsensitive]) == .orderedSame }) {
            return sanitized
        }
        var counter = 2
        while true {
            let candidate = "\(sanitized)-\(counter)"
            if !project.servers.contains(where: { $0.alias.compare(candidate, options: [.caseInsensitive]) == .orderedSame }) {
                return candidate
            }
            counter += 1
        }
    }

    private func fallbackAlias(in project: Project) -> String {
        var counter = 1
        while true {
            let candidate = "imported-server-\(counter)"
            if !project.servers.contains(where: { $0.alias.compare(candidate, options: [.caseInsensitive]) == .orderedSame }) {
                return candidate
            }
            counter += 1
        }
    }

    private func runHealthCheck(for server: Server) {
        Task.detached(priority: .utility) {
            let provider = CapabilitiesService.provider(for: server)
            do {
                let capabilities = try await provider.fetchCapabilities(for: server)
                let payload = try? JSONEncoder().encode(capabilities)
                await MainActor.run {
                    server.lastHealth = .healthy
                    server.lastCheckedAt = Date()
                    if let payload {
                        server.replaceCapabilityCache(payload: payload,
                                                      generatedAt: Date(),
                                                      in: server.modelContext)
                    }
                }
            } catch {
                await MainActor.run {
                    server.lastHealth = .unhealthy
                    server.lastCheckedAt = Date()
                }
            }
        }
    }

    enum ImportError: Error {
        case unrecognizedFormat
        case unsupportedFormat
    }

    func message(for error: ImportError) -> String {
        switch error {
        case .unrecognizedFormat:
            return "Unable to detect any MCP servers in the provided data."
        case .unsupportedFormat:
            return "Import format metadata is incomplete."
        }
    }

    private func parse(data: Data,
                       format: ClientInstallInstruction.ConfigFile.ImportFormat,
                       description: String) async throws -> ImportParseResult {
        let candidates: [ImportCandidate]
        switch format.type {
        case .jsonPointer:
            candidates = try parseJSONPointer(data: data, format: format)
        case .tomlTable:
            candidates = try parseTOML(data: data, format: format)
        case .regex:
            candidates = try parseRegex(data: data, format: format)
        }
        return ImportParseResult(sourceDescription: description,
                                 candidates: candidates,
                                 errors: [])
    }

    private func parseJSONPointer(data: Data,
                                  format: ClientInstallInstruction.ConfigFile.ImportFormat) throws -> [ImportCandidate] {
        guard let pointer = format.serverPointer else {
            throw ImportError.unsupportedFormat
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.unrecognizedFormat
        }
        guard let target = JSONPointerNavigator.value(at: pointer, in: json) else {
            throw ImportError.unrecognizedFormat
        }

        if let dict = target as? [String: Any] {
            return dict.map { key, value in
                candidateFromJSONEntry(aliasSource: .key(key: key),
                                       payload: value,
                                       format: format)
            }
        }

        if let array = target as? [Any] {
            return array.map { value in
                candidateFromJSONEntry(aliasSource: .field(name: format.aliasSource ?? "alias"),
                                       payload: value,
                                       format: format)
            }
        }

        throw ImportError.unrecognizedFormat
    }

    private func parseTOML(data: Data,
                           format: ClientInstallInstruction.ConfigFile.ImportFormat) throws -> [ImportCandidate] {
        guard let prefix = format.tablePrefix else {
            throw ImportError.unsupportedFormat
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.unrecognizedFormat
        }
        let tables = SimpleTOMLParser().parseTables(from: text)
        let matching = tables.filter { $0.key.hasPrefix(prefix) }
        return matching.map { key, values in
            let alias = String(key.dropFirst(prefix.count))
            return candidateFromDictionary(alias: alias,
                                           values: values,
                                           fieldMap: format.fieldMap,
                                           sourceDescription: "TOML")
        }
    }

    private func parseRegex(data: Data,
                            format: ClientInstallInstruction.ConfigFile.ImportFormat) throws -> [ImportCandidate] {
        guard let pattern = format.pattern else {
            throw ImportError.unsupportedFormat
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.unrecognizedFormat
        }
        let parser = RegexImportParser(pattern: pattern,
                                       options: format.options ?? [],
                                       fieldMap: format.fieldMap,
                                       aliasSource: format.aliasSource)
        return parser.parse(text: text)
    }

    private enum AliasSource {
        case key(key: String)
        case field(name: String)
    }

    private func candidateFromJSONEntry(aliasSource: AliasSource,
                                        payload: Any,
                                        format: ClientInstallInstruction.ConfigFile.ImportFormat) -> ImportCandidate {
        guard let dict = payload as? [String: Any] else {
            return ImportCandidate(alias: "(invalid)",
                                   summary: ImportCandidateSummary(transportLabel: "Unknown",
                                                                   executable: "",
                                                                   remoteURL: "",
                                                                   arguments: "",
                                                                   envSummary: "",
                                                                   headerSummary: "",
                                                                   enabledSummary: ""),
                                   details: [],
                                   envVars: [],
                                   headers: [],
                                   server: nil,
                                   error: "Entry is not an object")
        }

        let alias: String
        switch aliasSource {
        case .key(let key):
            alias = key
        case .field(let name):
            let value = dict[name]
            alias = value as? String ?? "Unnamed"
        }

        return candidateFromDictionary(alias: alias,
                                       values: dict,
                                       fieldMap: format.fieldMap,
                                       sourceDescription: "JSON")
    }

    private func candidateFromDictionary(alias: String,
                                         values: [String: Any],
                                         fieldMap: [String: String]?,
                                         sourceDescription: String) -> ImportCandidate {
        let normalized = NormalizedServerBuilder(values: values,
                                                 fieldMap: fieldMap ?? [:],
                                                 alias: alias).build()
        let summary = makeImportSummary(for: normalized.server)
        return ImportCandidate(alias: normalized.alias,
                               summary: summary,
                               details: normalized.details,
                               envVars: normalized.envDetails,
                               headers: normalized.headerDetails,
                               server: normalized.server,
                               error: normalized.error)
    }
}

func makeImportSummary(for server: ImportedServerDefinition?) -> ImportCandidateSummary {
    guard let server else {
        return ImportCandidateSummary(transportLabel: "Unknown",
                                      executable: "—",
                                      remoteURL: "—",
                                      arguments: "—",
                                      envSummary: "—",
                                      headerSummary: "—",
                                      enabledSummary: "—")
    }
    let transport = server.kind == .local_stdio ? "STDIO" : "HTTP/SSE"
    let exec = server.execPath ?? "—"
    let url = server.baseURL ?? "—"
    let args = server.args.isEmpty ? "No args" : server.args.joined(separator: " ")
    let env = server.env.isEmpty ? "0 vars" : "\(server.env.count) vars"
    let headers = server.headers.isEmpty ? "0 headers" : "\(server.headers.count) headers"
    let enabled = server.isEnabled ? "Enabled" : "Disabled"
    return ImportCandidateSummary(transportLabel: transport,
                                  executable: exec,
                                  remoteURL: url,
                                  arguments: args,
                                  envSummary: env,
                                  headerSummary: headers,
                                  enabledSummary: enabled)
}

private struct NormalizedServerResult {
    let alias: String
    let server: ImportedServerDefinition?
    let details: [ImportFieldDetail]
    let envDetails: [ImportFieldDetail]
    let headerDetails: [ImportFieldDetail]
    let error: String?
}

private struct NormalizedServerBuilder {
    let values: [String: Any]
    let fieldMap: [String: String]
    let alias: String

    func build() -> NormalizedServerResult {
        var execPath = stringValue(for: .command)
        let args = arrayValue(for: .args)
        let url = stringValue(for: .url)
        let env = dictionaryValue(for: .env)
        let headers = dictionaryValue(for: .headers)
        let isEnabled = boolValue(for: .enabled) ?? true
        let kind: ServerKind
        if let url, !url.isEmpty {
            kind = .remote_http_sse
        } else {
            kind = .local_stdio
        }

        if kind == .local_stdio && (execPath?.isEmpty ?? true) {
            return NormalizedServerResult(alias: alias,
                                          server: nil,
                                          details: [],
                                          envDetails: [],
                                          headerDetails: [],
                                          error: "Missing executable command")
        }
        if kind == .remote_http_sse && (url?.isEmpty ?? true) {
            return NormalizedServerResult(alias: alias,
                                          server: nil,
                                          details: [],
                                          envDetails: [],
                                          headerDetails: [],
                                          error: "Missing base URL")
        }

        let definition = ImportedServerDefinition(alias: alias,
                                                  kind: kind,
                                                  execPath: execPath,
                                                  args: args,
                                                  cwd: nil,
                                                  env: env,
                                                  headers: headers,
                                                  baseURL: url,
                                                  includeTools: [],
                                                  isEnabled: isEnabled)
        var details: [ImportFieldDetail] = []
        if let execPath {
            details.append(ImportFieldDetail(label: kind == .local_stdio ? "Executable" : "Command", value: execPath))
        }
        if !args.isEmpty {
            details.append(ImportFieldDetail(label: "Arguments", value: args.joined(separator: " ")))
        }
        if let url {
            details.append(ImportFieldDetail(label: "URL", value: url))
        }
        let envDetails = env.map { ImportFieldDetail(label: $0.key, value: $0.value) }
        let headerDetails = headers.map { ImportFieldDetail(label: $0.key, value: $0.value) }
        return NormalizedServerResult(alias: alias,
                                      server: definition,
                                      details: details,
                                      envDetails: envDetails,
                                      headerDetails: headerDetails,
                                      error: nil)
    }

    private enum Field: String {
        case command
        case args
        case env
        case headers
        case url
        case enabled
    }

    private func key(for field: Field) -> String {
        fieldMap[field.rawValue] ?? field.rawValue
    }

    private func stringValue(for field: Field) -> String? {
        let keyName = key(for: field)
        guard let value = values[keyName] else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func arrayValue(for field: Field) -> [String] {
        let keyName = key(for: field)
        guard let value = values[keyName] else { return [] }
        if let array = value as? [String] {
            return array
        }
        if let anyArray = value as? [Any] {
            return anyArray.compactMap { element in
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

    private func dictionaryValue(for field: Field) -> [String: String] {
        let keyName = key(for: field)
        guard let value = values[keyName] else { return [:] }
        if let dictionary = value as? [String: String] {
            return dictionary
        }
        if let anyDict = value as? [String: Any] {
            var normalized: [String: String] = [:]
            for (key, element) in anyDict {
                if let string = element as? String {
                    normalized[key] = string
                } else if let number = element as? NSNumber {
                    normalized[key] = number.stringValue
                }
            }
            return normalized
        }
        return [:]
    }

    private func boolValue(for field: Field) -> Bool? {
        let keyName = key(for: field)
        guard let value = values[keyName] else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(normalized) { return true }
            if ["false", "no", "0"].contains(normalized) { return false }
        }
        return nil
    }
}

private enum JSONPointerNavigator {
    static func value(at pointer: String, in object: Any) -> Any? {
        guard pointer.starts(with: "/") else { return nil }
        let components = pointer.split(separator: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
        var current: Any? = object
        for component in components where !component.isEmpty {
            if let dict = current as? [String: Any] {
                current = dict[String(component)]
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }
}

private struct SimpleTOMLParser {
    func parseTables(from text: String) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        var currentTable: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentTable = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if result[currentTable!] == nil {
                    result[currentTable!] = [:]
                }
                continue
            }
            guard let table = currentTable,
                  let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueString = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedValue = parseValue(valueString)
            result[table]?[key] = parsedValue
        }
        return result
    }

    private func parseValue(_ value: String) -> Any {
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = value.dropFirst().dropLast()
            let components = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return components.map { component in
                if component.hasPrefix("\"") && component.hasSuffix("\"") {
                    return String(component.dropFirst().dropLast())
                }
                return component
            }
        }
        if value.lowercased() == "true" { return true }
        if value.lowercased() == "false" { return false }
        if let number = Double(value) { return number }
        return value
    }
}

private struct RegexImportParser {
    let pattern: String
    let options: [String]
    let fieldMap: [String: String]?
    let aliasSource: String?

    func parse(text: String) -> [ImportCandidate] {
        var opts: NSRegularExpression.Options = []
        for option in options {
            switch option.lowercased() {
            case "caseinsensitive": opts.insert(.caseInsensitive)
            case "allowcomments": opts.insert(.allowCommentsAndWhitespace)
            case "dotmatchesnewline": opts.insert(.dotMatchesLineSeparators)
            case "multiline": opts.insert(.anchorsMatchLines)
            default: break
            }
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else {
            return []
        }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        var candidates: [ImportCandidate] = []
        for match in matches {
            var values: [String: Any] = [:]
            if let fieldMap {
                for (canonical, group) in fieldMap {
                    guard let range = captureRange(named: group, in: match, text: text) else { continue }
                    let value = (text as NSString).substring(with: range)
                    values[canonical] = value
                }
            }
            let alias: String
            if let aliasSource,
               let range = captureRange(named: aliasSource, in: match, text: text) {
                alias = (text as NSString).substring(with: range)
            } else {
                alias = "Imported"
            }
            let builder = NormalizedServerBuilder(values: values,
                                                  fieldMap: [:],
                                                  alias: alias)
            let normalized = builder.build()
            let summary = makeImportSummary(for: normalized.server)
            let candidate = ImportCandidate(alias: normalized.alias,
                                            summary: summary,
                                            details: normalized.details,
                                            envVars: normalized.envDetails,
                                            headers: normalized.headerDetails,
                                            server: normalized.server,
                                            error: normalized.error)
            candidates.append(candidate)
        }
        return candidates
    }

    private func captureRange(named key: String,
                              in match: NSTextCheckingResult,
                              text: String) -> NSRange? {
        if key.allSatisfy({ $0.isNumber }),
           let index = Int(key),
           index > 0,
           index <= match.numberOfRanges {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : range
        }
        let named = match.range(withName: key)
        return named.location == NSNotFound ? nil : named
    }
}

extension ExternalConfigImporter.ImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "Unable to detect a supported MCP server definition."
        case .unsupportedFormat:
            return "Import metadata is missing required fields."
        }
    }
}
