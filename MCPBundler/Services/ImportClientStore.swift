import Foundation
import SwiftUI
import Combine

@MainActor
final class ImportClientStore: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    @Published private(set) var clients: [ImportClientDescriptor] = []
    @Published private(set) var knownFormats: [ClientInstallInstruction.ConfigFile.ImportFormat] = []

    private let bundle: Bundle
    private let executablePath: String
    private let fileManager: FileManager

    init(executablePath: String,
         bundle: Bundle = .main,
         fileManager: FileManager = .default) {
        self.bundle = bundle
        self.executablePath = executablePath
        self.fileManager = fileManager
        loadClients()
    }

    func reload() {
        loadClients()
    }

    private func loadClients() {
        let instructions = ClientInstallInstructionLoader.loadClients(executablePath: executablePath, bundle: bundle)
        clients = buildDescriptors(from: instructions)
        knownFormats = uniqueFormats(from: instructions)
    }

    private func buildDescriptors(from instructions: [ClientInstallInstruction]) -> [ImportClientDescriptor] {
        var descriptors: [ImportClientDescriptor] = []
        for instruction in instructions {
            guard let descriptor = descriptor(for: instruction) else { continue }
            descriptors.append(descriptor)
        }
        return descriptors.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func descriptor(for instruction: ClientInstallInstruction) -> ImportClientDescriptor? {
        guard !instruction.configFiles.isEmpty else { return nil }
        for config in instruction.configFiles {
            guard let format = config.importFormat else { continue }
            let resolved = resolvePath(config.path)
            guard let resolved else { continue }
            if fileManager.isReadableFile(atPath: resolved.path) {
                return ImportClientDescriptor(id: instruction.id,
                                              instructionID: instruction.id,
                                              displayName: instruction.displayName,
                                              configPath: config.path,
                                              resolvedURL: resolved,
                                              importFormat: format)
            }
        }
        return nil
    }

    private func uniqueFormats(from instructions: [ClientInstallInstruction]) -> [ClientInstallInstruction.ConfigFile.ImportFormat] {
        var seen: Set<ClientInstallInstruction.ConfigFile.ImportFormat> = []
        var formats: [ClientInstallInstruction.ConfigFile.ImportFormat] = []
        for instruction in instructions {
            for config in instruction.configFiles {
                guard let format = config.importFormat else { continue }
                if seen.insert(format).inserted {
                    formats.append(format)
                }
            }
        }
        return formats
    }

    private func resolvePath(_ rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedTilde = (trimmed as NSString).expandingTildeInPath
        let substituted = substituteEnvironmentVariables(in: expandedTilde)
        return URL(fileURLWithPath: substituted)
    }

    private func substituteEnvironmentVariables(in path: String) -> String {
        var result = path
        let env = ProcessInfo.processInfo.environment
        for (key, value) in env {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
            result = result.replacingOccurrences(of: "$\(key)", with: value)
            result = result.replacingOccurrences(of: "$(\(key))", with: value)
        }
        return result
    }
}
