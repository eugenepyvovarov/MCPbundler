import XCTest
import MCP
@testable import MCPBundler

// In-memory HTTP+SSE server using URLProtocol to validate the Swift SDK transport
// behavior: open SSE, accept POSTs at the SSE URL, and deliver JSON-RPC responses
// via SSE "message" events.

final class HTTPSSERemoteClientInMemoryTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockSSEURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(MockSSEURLProtocol.self)
        super.tearDown()
    }

    func testInitialize_ListTools_CallTool_overHTTP_SSE() async throws {
        let base = URL(string: "http://mock.local/v1/sse")!

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSSEURLProtocol.self] + (configuration.protocolClasses ?? [])

        let transport = HTTPClientTransport(endpoint: base,
                                            configuration: configuration,
                                            streaming: true)
        let client = Client(name: "InMemory", version: "1.0.0")

        _ = try await client.connect(transport: transport)

        // Validate initialize happened (implicit) by issuing listTools
        let (tools, _) = try await client.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "hello")

        // Call the mocked tool and assert SSE-delivered result
        let (content, isError) = try await client.callTool(name: "hello", arguments: ["x": .int(1)])
        XCTAssertEqual(isError ?? false, false)
        let joined = content.compactMap { c -> String? in
            if case let .text(s) = c { return s }
            return nil
        }.joined(separator: " ")
        XCTAssertTrue(joined.contains("pong"))

        await client.disconnect()
    }
}

private final class MockSSEURLProtocol: URLProtocol {
    // We route SSE and POSTs by normalized path; tests use http://mock.local/v1/sse
    private static let ssePath = "/v1/sse"
    private static var sseResponder: ((Data) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        if request.httpMethod == "GET", path == Self.ssePath {
            handleSSEHandshake()
            return
        }
        if request.httpMethod == "POST", path == Self.ssePath {
            handleJSONRPCPost()
            return
        }
        send(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8))
    }

    override func stopLoading() {}

    private func handleSSEHandshake() {
        let res = HTTPURLResponse(url: request.url!, statusCode: 200,
                                  httpVersion: "HTTP/1.1",
                                  headerFields: [
                                      "Content-Type": "text/event-stream",
                                      "Cache-Control": "no-cache",
                                      "Connection": "keep-alive"
                                  ])!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)

        // Capture responder to push future SSE events triggered by POSTs
        Self.sseResponder = { [weak self] data in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: data)
        }

        // Keep stream open; do not finishLoading here
    }

    private func handleJSONRPCPost() {
        guard let body = request.httpBody,
              let rpc = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            send(status: 400, headers: [:], body: Data())
            return
        }
        // Ack the POST with 202 per streamable HTTP semantics
        send(status: 202, headers: ["Content-Type": "text/plain"], body: Data())

        // Build an SSE JSON-RPC response matching the posted id
        let id = rpc["id"] ?? "1"
        let method = (rpc["method"] as? String) ?? ""
        let payload: [String: Any]
        if method == "initialize" {
            payload = [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
                    "serverInfo": ["name": "Mock", "version": "1.0"]
                ]
            ]
        } else if method == "tools/list" {
            payload = [
                "jsonrpc": "2.0", "id": id,
                "result": ["tools": [["name": "hello", "description": "hi", "inputSchema": ["type": "object"]]]]
            ]
        } else if method == "tools/call" {
            payload = [
                "jsonrpc": "2.0", "id": id,
                "result": ["content": [["type": "text", "text": "pong"]], "isError": false]
            ]
        } else {
            payload = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method"]]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            writeSSE(event: "message", data: String(decoding: data, as: UTF8.self))
        }
    }

    private func writeSSE(event: String? = nil, data: String) {
        var buf = Data()
        if let event { buf.append(Data("event: \(event)\n".utf8)) }
        for line in data.split(whereSeparator: \._isLineTerminator) {
            buf.append(Data("data: \(line)\n".utf8))
        }
        buf.append(Data("\n".utf8))
        Self.sseResponder?(buf)
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        let res = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
