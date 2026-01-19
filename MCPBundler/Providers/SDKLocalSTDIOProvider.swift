//
//  SDKLocalSTDIOProvider.swift
//  MCP Bundler
//
//  Provider for local STDIO MCP servers
//

import Foundation
import MCP
import SwiftData
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

final class SDKLocalSTDIOProvider: CapabilitiesProvider {
    @MainActor
    func fetchCapabilities(for server: Server) async throws -> MCPCapabilities {
        guard let exec = server.execPath, !exec.isEmpty else {
            throw CapabilityError.invalidConfiguration
        }

        let verboseLogging = ProcessInfo.processInfo.environment["MCP_BUNDLER_STDIO_VERBOSE"] == "1"
        let logAlias = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = normalizedAliasForLogs(logAlias)
        let baseCategory = "server.\(normalizedAlias).stdio"

        @MainActor
        func persistLog(level: LogLevel, category: String, message: String, metadata: [String: String]? = nil) {
            guard let project = server.project, let context = project.modelContext else { return }

            let metadataData: Data?
            if let metadata, !metadata.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                metadataData = try? encoder.encode(metadata)
            } else {
                metadataData = nil
            }

            let entry = LogEntry(project: project,
                                 timestamp: Date(),
                                 level: level,
                                 category: category,
                                 message: message,
                                 metadata: metadataData)
            context.insert(entry)
            try? context.save()
        }

        func logVerbose(_ message: String) {
            guard verboseLogging else { return }
            persistLog(level: .debug,
                       category: "\(baseCategory).test",
                       message: message,
                       metadata: ["alias": logAlias, "alias_normalized": normalizedAlias])
        }

        func logError(_ message: String) {
            persistLog(level: .error,
                       category: "\(baseCategory).test",
                       message: message,
                       metadata: ["alias": logAlias, "alias_normalized": normalizedAlias])
        }

        func logInfo(_ message: String) {
            persistLog(level: .info,
                       category: "\(baseCategory).test",
                       message: message,
                       metadata: ["alias": logAlias, "alias_normalized": normalizedAlias])
        }

        var env = [:] as [String: String]
        if let project = server.project {
            for e in project.envVars {
                if let v = e.plainValue { env[e.key] = v }
            }
        }
        for e in server.envOverrides {
            if let v = e.plainValue { env[e.key] = v }
        }
        if env["PATH"] == nil, let shellPath = getShellPath() {
            env["PATH"] = shellPath
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.arguments = server.args

        if exec.contains("/") {
            process.executableURL = URL(fileURLWithPath: exec)
        } else {
            guard let fullPath = findFullPath(for: exec, using: env) else {
                throw CapabilityError.executionFailed("Executable '\(exec)' not found in PATH")
            }
            process.executableURL = URL(fileURLWithPath: fullPath)
        }

        if let cwd = server.cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.environment = env.merging(ProcessInfo.processInfo.environment) { custom, _ in custom }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrCapture = StdioPipeCapture(limitBytes: 64 * 1024)

        let execPathForLog = process.executableURL?.path ?? exec
        let cwdPathForLog = process.currentDirectoryURL?.path ?? "(default)"
        let envKeysForLog = Array(env.keys).sorted()
        let argsForLog = process.arguments ?? []
        logVerbose("Starting STDIO test exec=\(execPathForLog) cwd=\(cwdPathForLog) args=\(argsForLog) env_keys=\(envKeysForLog)")

        var phase = "spawn"
        do {
            try process.run()
        } catch {
            logError("STDIO test failed phase=\(phase): \(error.localizedDescription)")
            throw CapabilityError.executionFailed("Failed to run process: \(error)")
        }

        let stderrTask = stderrCapture.startReading(from: stderrPipe.fileHandleForReading)

        logVerbose("Spawned PID=\(process.processIdentifier)")

        let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: inputFD, output: outputFD)

        let client = Client(name: "MCPBundler", version: "0.1.0")
        let cleanup: @Sendable () async -> Void = {
            await client.disconnect()
            await transport.disconnect()
            if process.isRunning {
                process.terminate()
            }
        }

        do {
            phase = "initialize"
            logVerbose("Connecting (initialize)…")
            let initResult = try await client.connect(transport: transport)

            var toolsDTO: [MCPTool] = []
            var resourcesDTO: [MCPResource] = []
            var promptsDTO: [MCPPrompt] = []

            if initResult.capabilities.tools != nil {
                phase = "tools/list"
                logVerbose("Fetching tools (tools/list)…")
                let (tools, _) = try await client.listTools()
                toolsDTO = tools.map { tool in
                    let annotations: Tool.Annotations? = tool.annotations.isEmpty ? nil : tool.annotations
                    return MCPTool(
                        name: tool.name,
                        title: annotations?.title,
                        description: tool.description,
                        inputSchema: tool.inputSchema,
                        annotations: annotations
                    )
                }
            }
            if initResult.capabilities.resources != nil {
                phase = "resources/list"
                logVerbose("Fetching resources (resources/list)…")
                do {
                    let (resources, _) = try await client.listResources()
                    resourcesDTO = resources.map { MCPResource(name: $0.name, uri: $0.uri, description: $0.description) }
                } catch let mcpError as MCPError {
                    if case .methodNotFound = mcpError {
                        logInfo("Skipping resources/list (\(mcpError.localizedDescription))")
                    } else {
                        throw mcpError
                    }
                }
            }
            if initResult.capabilities.prompts != nil {
                phase = "prompts/list"
                logVerbose("Fetching prompts (prompts/list)…")
                do {
                    let (prompts, _) = try await client.listPrompts()
                    promptsDTO = prompts.map { MCPPrompt(name: $0.name, description: $0.description) }
                } catch let mcpError as MCPError {
                    if case .methodNotFound = mcpError {
                        logInfo("Skipping prompts/list (\(mcpError.localizedDescription))")
                    } else {
                        throw mcpError
                    }
                }
            }

            await cleanup()

            stderrPipe.fileHandleForReading.closeFile()
            let errorData = await stderrTask.value
            let errorMsg = String(decoding: errorData, as: UTF8.self)
            let trimmedError = errorMsg.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedError.isEmpty {
                persistLog(level: .debug,
                           category: "\(baseCategory).stderr",
                           message: trimmedError,
                           metadata: ["alias": logAlias, "alias_normalized": normalizedAlias, "phase": phase])
            }

            logVerbose("STDIO test succeeded tools=\(toolsDTO.count) resources=\(resourcesDTO.count) prompts=\(promptsDTO.count)")

            return MCPCapabilities(
                serverName: initResult.serverInfo.name,
                serverDescription: initResult.instructions,
                tools: toolsDTO,
                resources: resourcesDTO.isEmpty ? nil : resourcesDTO,
                prompts: promptsDTO.isEmpty ? nil : promptsDTO
            )
        } catch {
            await cleanup()
            stderrPipe.fileHandleForReading.closeFile()
            let errorData = await stderrTask.value
            let errorMsg = String(decoding: errorData, as: UTF8.self)
            let trimmedError = errorMsg.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedError.isEmpty {
                persistLog(level: .debug,
                           category: "\(baseCategory).stderr",
                           message: trimmedError,
                           metadata: ["alias": logAlias, "alias_normalized": normalizedAlias, "phase": phase])
            }
            logError("STDIO test failed phase=\(phase): \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Helper functions

func findFullPath(for executable: String, using environment: [String: String]) -> String? {
    guard let pathEnv = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] else {
        return nil
    }
    let pathComponents = pathEnv.split(separator: ":").map(String.init)
    for directory in pathComponents {
        let executablePath = directory.hasSuffix("/") ?
            directory + executable :
            directory + "/" + executable
        if FileManager.default.isExecutableFile(atPath: executablePath) {
            return executablePath
        }
    }
    return nil
}

// MARK: - Helper functions

private func getShellPath() -> String? {
    // Try to get the PATH from the user's shell
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "echo $PATH"]

    let pipe = Pipe()
    process.standardOutput = pipe

    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0,
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return path
        }
    } catch {
        // Fall back to environment PATH
        return ProcessInfo.processInfo.environment["PATH"]
    }

    return ProcessInfo.processInfo.environment["PATH"]
}

private func normalizedAliasForLogs(_ alias: String) -> String {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "unnamed" }
    return trimmed.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
}

private final class StdioPipeCapture: @unchecked Sendable {
    nonisolated(unsafe) private let limitBytes: Int
    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var captured = Data()

    init(limitBytes: Int) {
        self.limitBytes = max(0, limitBytes)
    }

    nonisolated func startReading(from handle: FileHandle) -> Task<Data, Never> {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return Data() }
            let chunkSize = 4096
            while !Task.isCancelled {
                let nextChunk: Data?
                do {
                    nextChunk = try handle.read(upToCount: chunkSize)
                } catch {
                    break
                }

                guard let nextChunk, !nextChunk.isEmpty else { break }
                self.appendCaptured(nextChunk)
            }
            return self.snapshot()
        }
    }

    nonisolated private func appendCaptured(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        if limitBytes == 0 { return }

        if captured.count >= limitBytes {
            return
        }

        if captured.count + data.count <= limitBytes {
            captured.append(data)
        } else {
            let remaining = limitBytes - captured.count
            captured.append(data.prefix(remaining))
        }
    }

    nonisolated private func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}
