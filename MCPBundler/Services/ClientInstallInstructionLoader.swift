//
//  ClientInstallInstructionLoader.swift
//  MCP Bundler
//
//  Loads installation instructions for each supported client from the
//  bundled JSON resources.
//

import Foundation
import os.log

enum ClientInstallInstructionLoader {
    private static let logger = Logger(subsystem: "app.mcpbundler.install", category: "ClientInstallInstructionLoader")
    private static let defaultPlaceholders = [
        "/Applications/MCPBundler.app/Contents/MacOS/MCPBundler"
    ]

    static func loadClients(executablePath: String, bundle: Bundle = .main) -> [ClientInstallInstruction] {
        guard let resourceURLs = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Install/clients") else {
            logger.error("Unable to locate install instruction resources in bundle.")
            return []
        }

        var instructions: [ClientInstallInstruction] = []
        let decoder = JSONDecoder()

        for url in resourceURLs {
            do {
                let data = try Data(contentsOf: url)
                let instruction = try decoder.decode(ClientInstallInstruction.self, from: data)
                let resolved = instruction.replacingExecutablePath(with: executablePath, placeholders: defaultPlaceholders)
                instructions.append(resolved)
            } catch {
                logger.error("Failed to decode install instructions at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return instructions.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
