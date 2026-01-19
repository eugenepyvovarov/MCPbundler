import Foundation
import Logging
import MCP
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif
#if canImport(Darwin)
import Darwin.POSIX
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// STDIO transport that relies on blocking reads so idle sessions stay cold.
actor BundlerStdioTransport: Transport {
    private let input: FileDescriptor
    private let inputHandle: FileHandle
    private let output: FileDescriptor
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let verboseLogging: Bool

    private let minBackoffMilliseconds = 1500
    private let maxBackoffMilliseconds = 3000

    init(
        input: FileDescriptor = .standardInput,
        output: FileDescriptor = .standardOutput,
        logger: Logger? = nil
    ) {
        self.input = input
        self.inputHandle = FileHandle(fileDescriptor: input.rawValue, closeOnDealloc: false)
        self.output = output
        self.logger = logger ?? Logger(label: "mcp.transport.stdio") { _ in SwiftLogNoOpLogHandler() }
        self.verboseLogging = ProcessInfo.processInfo.environment["MCP_BUNDLER_STDIO_VERBOSE"] == "1"

        var streamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    func connect() async throws {
        guard !isConnected else { return }

        isConnected = true
        logger.debug("Transport connected successfully")

        Task { await readLoop() }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        continuation.finish()
        logger.debug("Transport disconnected")
    }

    func send(_ message: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        var messageWithNewline = message
        messageWithNewline.append(UInt8(ascii: "\n"))

        var remaining = messageWithNewline
        var backoff = minBackoffMilliseconds

        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer -> Int in
                    try output.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                    backoff = minBackoffMilliseconds
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try? await Task.sleep(for: .milliseconds(backoff))
                backoff = min(maxBackoffMilliseconds, max(minBackoffMilliseconds, backoff * 2))
                continue
            } catch {
                throw MCPError.transportError(error)
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    // MARK: - Private

    private func readLoop() async {
        var pendingData = Data()

        do {
            for try await byte in inputHandle.bytes {
                if Task.isCancelled || !isConnected {
                    break
                }

                pendingData.append(byte)

                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageSlice = pendingData[..<newlineIndex]
                    pendingData.removeSubrange(...newlineIndex)

                    if !messageSlice.isEmpty {
                        let frame = Data(messageSlice)
                        let trimmed = frame.drop { byte in
                            byte == UInt8(ascii: " ") ||
                            byte == UInt8(ascii: "\t") ||
                            byte == UInt8(ascii: "\r") ||
                            byte == UInt8(ascii: "\n")
                        }

                        if let first = trimmed.first, first == UInt8(ascii: "[") {
                            logger.error("Batch requests are not supported; rejecting payload", metadata: ["size": "\(frame.count)"])
                            await sendBatchNotSupportedError()
                            continue
                        }

                        logger.trace("Message received", metadata: ["size": "\(frame.count)"])
                        continuation.yield(frame)
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                logger.error("Read error occurred", metadata: ["error": "\(error)"])
                debugLog("read error: \(error)")
            }
        }

        if isConnected {
            logger.notice("EOF received")
            debugLog("stdin closed; terminating stdio transport")
        }

        continuation.finish()
    }

    private func sendBatchNotSupportedError() async {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": [
                "code": -32600,
                "message": "Batch requests are not supported by MCP Bundler"
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? await send(data)
    }

    private func debugLog(_ message: String) {
        guard verboseLogging else { return }
        let formatted = "mcp-bundler.transport: \(message)\n"
        if let data = formatted.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
