import XCTest
import SwiftData
import Foundation
import Darwin
@testable import MCPBundler

@MainActor
final class HeadlessStdIOSmokeTests: XCTestCase {
    func testDebugHeadlessServerProvidesToolsList() async throws {
        guard ProcessInfo.processInfo.environment["MCP_BUNDLER_SMOKE_TEST"] == "1" else {
            throw XCTSkip("Set MCP_BUNDLER_SMOKE_TEST=1 to run the headless STDIO smoke test.")
        }
        guard let executableURL = Self.debugExecutableURL else {
            throw XCTSkip("Debug MCPBundler.app not found next to test bundle.")
        }

        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let storeURL = tempDirectory.appendingPathComponent("mcp-bundler.sqlite")

        let container = try TestModelContainerFactory.makePersistentContainer(at: storeURL)
        let context = container.mainContext

        let project = Project(name: "CLI Integration", isActive: true)
        context.insert(project)

        let server = Server(project: project, alias: "demo", kind: .remote_http_sse)
        server.isEnabled = true
        project.servers.append(server)
        _ = try TestCapabilitiesBuilder.prime(server: server)
        try context.save()

        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        try context.save()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--stdio-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["MCP_BUNDLER_STORE_URL"] = storeURL.path
        environment["MCP_BUNDLER_PERSIST_STDIO"] = "0"
        environment["MCP_BUNDLER_STDIO_VERBOSE"] = "1"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let reader = LineReader(fileHandle: stdoutPipe.fileHandleForReading)
        var didCloseStdin = false

        func sendRequest(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            var message = data
            message.append(0x0A)
            stdinPipe.fileHandleForWriting.write(message)
        }

        func nextJSONResponse(timeout: TimeInterval = 10) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    XCTFail("Timed out waiting for JSON response")
                    throw ResponseError.timeout
                }
                let line = try reader.readLine(timeout: remaining)
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                if let json = try? HeadlessStdIOSmokeTests.decode(line: line) {
                    return json
                }
            }
        }

        defer {
            if !didCloseStdin {
                stdinPipe.fileHandleForWriting.closeFile()
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            if let stderrData = try? stderrPipe.fileHandleForReading.readDataToEndOfFile(),
               let stderrString = String(data: stderrData, encoding: .utf8),
               !stderrString.isEmpty {
                let attachment = XCTAttachment(string: stderrString)
                attachment.name = "Headless stderr"
                attachment.lifetime = .deleteOnSuccess
                add(attachment)
            }
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
        }

        try sendRequest([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "TestHarness", "version": "1.0"],
                "capabilities": [:]
            ]
        ])

        let initializeResponse = try nextJSONResponse()
        XCTAssertEqual(initializeResponse["id"] as? Int, 1)
        let initResult = initializeResponse["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2025-03-26")

        try sendRequest([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:]
        ])

        let toolsResponse = try nextJSONResponse()
        XCTAssertEqual(toolsResponse["id"] as? Int, 2)

        guard
            let toolsResult = toolsResponse["result"] as? [String: Any],
            let tools = toolsResult["tools"] as? [[String: Any]]
        else {
            XCTFail("tools/list did not return a tools array")
            return
        }

        XCTAssertFalse(tools.isEmpty, "Expected at least one tool in response")
        let toolNames = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(toolNames.contains(where: { $0.hasPrefix("demo__") }),
                      "Expected namespaced tools for demo server, got \(toolNames)")

        stdinPipe.fileHandleForWriting.closeFile()
        didCloseStdin = true
        process.waitUntilExit()

        let logsContainer = try TestModelContainerFactory.makePersistentContainer(at: storeURL)
        let logsContext = logsContainer.mainContext
        var descriptor = FetchDescriptor<LogEntry>(sortBy: [SortDescriptor(\LogEntry.timestamp, order: .reverse)])
        descriptor.fetchLimit = 200
        let entries = try logsContext.fetch(descriptor)
        let decoder = JSONDecoder()

        let requestLogs = entries.filter { $0.category == "mcp-request" && $0.message == "tools/list" }
        XCTAssertFalse(requestLogs.isEmpty, "Expected at least one persisted mcp-request tools/list log entry.")

        let clientMatches = requestLogs.compactMap { entry -> [String: String]? in
            guard let data = entry.metadata else { return nil }
            return try? decoder.decode([String: String].self, from: data)
        }
        XCTAssertTrue(clientMatches.contains(where: { $0["mcp_client_name"] == "TestHarness" && $0["mcp_client_version"] == "1.0" }),
                      "Expected mcp_client_name/version metadata to match initialize clientInfo.")
    }

    private static var debugExecutableURL: URL? {
        let bundleURL = Bundle(for: HeadlessStdIOSmokeTests.self).bundleURL
        let productsURL = bundleURL.deletingLastPathComponent()
        let appURL = productsURL.appendingPathComponent("MCPBundler.app")
        let executable = appURL.appendingPathComponent("Contents/MacOS/MCPBundler")
        return FileManager.default.fileExists(atPath: executable.path) ? executable : nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("mcpbundler-headless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func decode(line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HeadlessStdIOSmokeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Line was not a JSON object: \(line)"])
        }
        return object
    }
}

private enum ResponseError: Error {
    case timeout
}

private struct LineReader {
    enum ReaderError: Error {
        case timeout
        case closed
        case invalidEncoding
    }

    private let fileDescriptor: Int32

    init(fileHandle: FileHandle) {
        self.fileDescriptor = fileHandle.fileDescriptor
    }

    func readLine(timeout: TimeInterval) throws -> String {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw ReaderError.timeout
            }

            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let waitMilliseconds = Int32(ceil(remaining * 1000))
            let pollResult = withUnsafeMutablePointer(to: &descriptor) {
                poll($0, 1, waitMilliseconds)
            }

            if pollResult == 0 {
                throw ReaderError.timeout
            }

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            if descriptor.revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                let readResult = Darwin.read(fileDescriptor, &byte, 1)
                if readResult == 0 {
                    throw ReaderError.closed
                } else if readResult < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                if byte == UInt8(ascii: "\n") {
                    break
                } else if byte != UInt8(ascii: "\r") {
                    buffer.append(byte)
                }
            } else if descriptor.revents & Int16(POLLHUP) != 0 {
                throw ReaderError.closed
            } else if descriptor.revents & Int16(POLLERR) != 0 {
                throw ReaderError.closed
            }
        }

        guard let string = String(data: buffer, encoding: .utf8) else {
            throw ReaderError.invalidEncoding
        }
        return string
    }
}
