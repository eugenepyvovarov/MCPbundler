import XCTest
import Logging
@testable import MCP

final class TransportStatusAndLoggingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        InMemoryHTTPSSEServer.register()
    }
    override class func tearDown() {
        InMemoryHTTPSSEServer.unregister()
        super.tearDown()
    }

    func test_suppressesWarningFor202TextPlain() async throws {
        // Configure server to accept POST at the SSE URL with an immediate stream
        InMemoryHTTPSSEServer.reset()
        InMemoryHTTPSSEServer.config.emitEndpointAfter = 0
        InMemoryHTTPSSEServer.config.initialBasePostStatus = nil

        // Custom logger to capture warnings
        final class CapturingHandler: LogHandler {
            var metadata: Logger.Metadata = [:]
            var logLevel: Logger.Level = .trace
            var warnings: [String] = []
            subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
                get { metadata[metadataKey] }
                set { metadata[metadataKey] = newValue }
            }
            func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
                if level >= .warning { warnings.append(message.description) }
            }
        }
        let handler = CapturingHandler()
        let logger = Logger(label: "test") { _ in handler }

        // Use a custom session injecting the protocol
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSEURLProtocol.self]
        let transport = HTTPClientTransport(endpoint: InMemoryHTTPSSEServer.config.baseURL,
                                            configuration: config,
                                            streaming: true,
                                            requestModifier: { $0 },
                                            logger: logger)
        let client = Client(name: "t", version: "1.0")
        _ = try await client.connect(transport: transport)
        _ = try await client.listTools() // POST returns 202 text/plain; response via SSE
        // Ensure no transport warning for 202 text/plain
        XCTAssertTrue(handler.warnings.filter { $0.contains("Unexpected content type") }.isEmpty)
        await client.disconnect()
    }
}
