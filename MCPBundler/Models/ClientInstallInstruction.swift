//
//  ClientInstallInstruction.swift
//  MCP Bundler
//
//  Defines the structured representation of per-client installation
//  instructions that back the headless connection UX.
//

import Foundation

struct ClientInstallInstruction: Decodable, Identifiable, Hashable {
    enum ClientCategory: String, Decodable, CaseIterable, Hashable, Identifiable {
        case cli
        case gui
        case jsonConfig = "json-config"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cli: return "CLI Tools"
            case .gui: return "GUI Apps"
            case .jsonConfig: return "Config Files"
            }
        }
    }

    struct PrimaryAction: Decodable, Hashable {
        enum ActionType: String, Decodable {
            case command
            case deeplink
            case gui
        }

        let type: ActionType
        var shellSnippet: String?
        var codeSnippet: String?
        var uxSnippet: String?
        var deeplinkUrl: String?
        var deeplinkLabel: String?
    }

    struct ConfigFile: Decodable, Hashable, Identifiable {
        var id: String { path }
        let path: String
        let format: String
        var snippet: String?
        var importFormat: ImportFormat?

        struct ImportFormat: Decodable, Hashable {
            enum FormatType: String, Decodable {
                case jsonPointer = "json-pointer"
                case regex
                case tomlTable = "toml-table"
            }

            let type: FormatType
            var serverPointer: String?
            var aliasSource: String?
            var fieldMap: [String: String]?
            var tablePrefix: String?
            var pattern: String?
            var options: [String]?

            var summary: String {
                switch type {
                case .jsonPointer:
                    var components: [String] = []
                    if let pointer = serverPointer {
                        components.append("Servers at \(pointer)")
                    }
                    if let aliasSource {
                        components.append("Alias via \(aliasSource)")
                    }
                    if let fieldMap, !fieldMap.isEmpty {
                        components.append("Fields: \(fieldMap.keys.joined(separator: ", "))")
                    }
                    return components.isEmpty ? "JSON pointer import" : components.joined(separator: " • ")
                case .regex:
                    return "Regex import pattern"
                case .tomlTable:
                    var components: [String] = []
                    if let prefix = tablePrefix {
                        components.append("Tables prefixed with \(prefix)")
                    }
                    return components.isEmpty ? "TOML table import" : components.joined(separator: " • ")
                }
            }
        }
    }

    let id: String
    let displayName: String
    let category: ClientCategory
    var primaryAction: PrimaryAction
    var configFiles: [ConfigFile]
    var notes: [String]
    var docsUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case category
        case primaryAction
        case configFiles
        case notes
        case docsUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        category = try container.decode(ClientCategory.self, forKey: .category)
        primaryAction = try container.decode(PrimaryAction.self, forKey: .primaryAction)
        configFiles = try container.decodeIfPresent([ConfigFile].self, forKey: .configFiles) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        docsUrl = try container.decodeIfPresent(String.self, forKey: .docsUrl)
    }

    func replacingExecutablePath(with newPath: String, placeholders: [String]) -> ClientInstallInstruction {
        var updated = self
        updated.primaryAction = primaryAction.replacingExecutablePath(with: newPath, placeholders: placeholders)
        updated.configFiles = configFiles.map { $0.replacingExecutablePath(with: newPath, placeholders: placeholders) }
        updated.notes = notes.map { note in
            placeholders.reduce(note) { partialResult, placeholder in
                partialResult.replacingOccurrences(of: placeholder, with: newPath)
            }
        }
        return updated
    }
}

extension ClientInstallInstruction.PrimaryAction {
    fileprivate func replacingExecutablePath(with newPath: String, placeholders: [String]) -> ClientInstallInstruction.PrimaryAction {
        var updated = self
        updated.shellSnippet = updated.shellSnippet?.replacingExecutablePath(with: newPath, placeholders: placeholders)
        updated.codeSnippet = updated.codeSnippet?.replacingExecutablePath(with: newPath, placeholders: placeholders)
        updated.uxSnippet = updated.uxSnippet?.replacingExecutablePath(with: newPath, placeholders: placeholders)
        updated.deeplinkUrl = updated.deeplinkUrl?.replacingExecutablePath(with: newPath, placeholders: placeholders)
        updated.deeplinkLabel = updated.deeplinkLabel?.replacingExecutablePath(with: newPath, placeholders: placeholders)
        return updated
    }
}

extension ClientInstallInstruction.ConfigFile {
    fileprivate func replacingExecutablePath(with newPath: String, placeholders: [String]) -> ClientInstallInstruction.ConfigFile {
        var updated = self
        updated.snippet = snippet?.replacingExecutablePath(with: newPath, placeholders: placeholders)
        return updated
    }
}

private extension String {
    func replacingExecutablePath(with newPath: String, placeholders: [String]) -> String {
        placeholders.reduce(self) { partialResult, placeholder in
            partialResult.replacingOccurrences(of: placeholder, with: newPath)
        }
    }
}
