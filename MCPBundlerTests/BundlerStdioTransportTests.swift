import XCTest
import MCP
import Logging
@testable import MCPBundler
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

@MainActor
final class BundlerStdioTransportTests: XCTestCase {
    func testRejectsBatchRequests() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        let inputDescriptor = FileDescriptor(rawValue: inputPipe.fileHandleForReading.fileDescriptor)
        let outputDescriptor = FileDescriptor(rawValue: outputPipe.fileHandleForWriting.fileDescriptor)

        let transport = BundlerStdioTransport(
            input: inputDescriptor,
            output: outputDescriptor,
            logger: Logger(label: "test.transport") { _ in SwiftLogNoOpLogHandler() }
        )

        try await transport.connect()

        let stream = transport.receive()
        var iterator = stream.makeAsyncIterator()

        // Write a batch payload into the transport.
        if let batchData = "[{\"jsonrpc\":\"2.0\",\"method\":\"noop\"}]\n".data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(batchData)
        }

        // Capture what the transport writes back.
        async let outputDataResult = outputPipe.fileHandleForReading.read(upToCount: 1024)

        // Give the read loop a moment to process.
        try await Task.sleep(nanoseconds: 200_000_000)

        // The batch should be rejected and not forwarded downstream.
        let forwarded = try await iterator.next()
        XCTAssertNil(forwarded)

        let outputData = try await outputDataResult ?? Data()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(outputString.contains("\"code\":-32600"))
        XCTAssertTrue(outputString.contains("Batch requests are not supported"))

        await transport.disconnect()

        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
    }

    func testPassesThroughMalformedJsonFrame() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        let inputDescriptor = FileDescriptor(rawValue: inputPipe.fileHandleForReading.fileDescriptor)
        let outputDescriptor = FileDescriptor(rawValue: outputPipe.fileHandleForWriting.fileDescriptor)

        let transport = BundlerStdioTransport(
            input: inputDescriptor,
            output: outputDescriptor,
            logger: Logger(label: "test.transport.malformed") { _ in SwiftLogNoOpLogHandler() }
        )

        try await transport.connect()

        let stream = transport.receive()
        var iterator = stream.makeAsyncIterator()

        if let malformed = "{\"jsonrpc\":\"2.0\",\"id\":1\n".data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(malformed)
        }

        let forwarded = try await iterator.next()
        XCTAssertNotNil(forwarded, "Transport should forward malformed frames without crashing")

        await transport.disconnect()

        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
    }

    func testDeliversMessageAfterDelayedInput() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        let inputDescriptor = FileDescriptor(rawValue: inputPipe.fileHandleForReading.fileDescriptor)
        let outputDescriptor = FileDescriptor(rawValue: outputPipe.fileHandleForWriting.fileDescriptor)

        let transport = BundlerStdioTransport(
            input: inputDescriptor,
            output: outputDescriptor,
            logger: Logger(label: "test.transport.delayed") { _ in SwiftLogNoOpLogHandler() }
        )

        try await transport.connect()

        let stream = transport.receive()
        var iterator = stream.makeAsyncIterator()

        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"noop\"}".utf8)
        let writerTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            var framedPayload = payload
            framedPayload.append(0x0A)
            inputPipe.fileHandleForWriting.write(framedPayload)
        }

        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, payload)

        await writerTask.value
        await transport.disconnect()

        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
    }

    func testSendDoesNotBlockWhenReadLoopIsWaiting() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        let inputDescriptor = FileDescriptor(rawValue: inputPipe.fileHandleForReading.fileDescriptor)
        let outputDescriptor = FileDescriptor(rawValue: outputPipe.fileHandleForWriting.fileDescriptor)

        let transport = BundlerStdioTransport(
            input: inputDescriptor,
            output: outputDescriptor,
            logger: Logger(label: "test.transport.blocking") { _ in SwiftLogNoOpLogHandler() }
        )

        try await transport.connect()

        // Start send while the read loop blocks waiting for stdin data.
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}".utf8)
        let sendTask = Task {
            try await transport.send(payload)
        }

        async let writtenData = outputPipe.fileHandleForReading.read(upToCount: payload.count + 1)

        _ = try await sendTask.value
        let data = try await writtenData ?? Data()
        var expected = payload
        expected.append(0x0A)
        XCTAssertEqual(data, expected)

        // Close stdin to end the read loop cleanly.
        inputPipe.fileHandleForWriting.closeFile()
        await transport.disconnect()

        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
    }

    func testStreamStaysOpenWhileInputWriterIsAlive() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        let inputDescriptor = FileDescriptor(rawValue: inputPipe.fileHandleForReading.fileDescriptor)
        let outputDescriptor = FileDescriptor(rawValue: outputPipe.fileHandleForWriting.fileDescriptor)

        let transport = BundlerStdioTransport(
            input: inputDescriptor,
            output: outputDescriptor,
            logger: Logger(label: "test.transport.idle") { _ in SwiftLogNoOpLogHandler() }
        )

        try await transport.connect()

        let stream = transport.receive()
        var iterator = stream.makeAsyncIterator()

        let expectation = XCTestExpectation(description: "Stream finished unexpectedly")
        expectation.isInverted = true

        let waitTask = Task {
            let result = try await iterator.next()
            if result == nil {
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 0.5)

        waitTask.cancel()
        inputPipe.fileHandleForWriting.closeFile()
        await transport.disconnect()

        outputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
    }
}
