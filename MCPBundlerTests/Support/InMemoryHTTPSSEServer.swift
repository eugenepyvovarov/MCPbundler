import Foundation
import XCTest

// A reusable in-memory HTTP+SSE server implemented via URLProtocol.
// It simulates the Streamable HTTP transport used by MCP servers:
//   - GET /v1/sse  => 200 text/event-stream (optional endpoint hint)
//   - POST /v1/sse => 202 ack; JSON-RPC result is delivered via SSE `message`

enum SSEEndpointVariant {
    case absolute
    case relative
    case jsonUrl
    case jsonEndpoint_sessionIdLower
    case jsonEndpoint_sessionIDUpper
}

final class InMemoryHTTPSSEServer {
    struct Config {
        var baseURL: URL = URL(string: "http://mock.local/v1/sse")!
        var emitEndpointHint: Bool = false
        var emitEndpointAfter: TimeInterval = 0
        var endpointVariant: SSEEndpointVariant = .relative
        var initialBasePostStatus: Int? = nil  // e.g., 404/405 to force fallback
        var sessionId: String = "TEST-SESSION"
        var tools: [[String: Any]] = [["name": "hello", "description": "hi", "inputSchema": ["type": "object"]]]
    }

    static var config = Config()

    // Observability
    static var lastGETHeaders: [String: String] = [:]
    static var lastPOSTHeaders: [String: String] = [:]
    static var lastPOSTURL: URL?
    static var basePOSTCount = 0
    static var sessionPOSTCount = 0

    static func reset() {
        lastGETHeaders = [:]
        lastPOSTHeaders = [:]
        lastPOSTURL = nil
        basePOSTCount = 0
        sessionPOSTCount = 0
    }

    static func register() {
        URLProtocol.registerClass(SSEURLProtocol.self)
    }

    static func unregister() {
        URLProtocol.unregisterClass(SSEURLProtocol.self)
    }
}

private final class SSEURLProtocol: URLProtocol {
    private static var sseResponder: ((Data) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let basePath = InMemoryHTTPSSEServer.config.baseURL.path
        if request.httpMethod == "GET", url.path == basePath {
            InMemoryHTTPSSEServer.lastGETHeaders = request.allHTTPHeaderFields ?? [:]
            handleSSEHandshake()
            return
        }
        if request.httpMethod == "POST", url.path == basePath {
            InMemoryHTTPSSEServer.lastPOSTHeaders = request.allHTTPHeaderFields ?? [:]
            InMemoryHTTPSSEServer.lastPOSTURL = url
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

        SSEURLProtocol.sseResponder = { [weak self] data in
            self?.client?.urlProtocol(self!, didLoad: data)
        }

        guard InMemoryHTTPSSEServer.config.emitEndpointHint else {
            return
        }

        let delay = InMemoryHTTPSSEServer.config.emitEndpointAfter
        let variant = InMemoryHTTPSSEServer.config.endpointVariant
        let sid = InMemoryHTTPSSEServer.config.sessionId
        let base = InMemoryHTTPSSEServer.config.baseURL
        let endpointAbs = base.absoluteString + "?sessionId=\(sid)"
        let endpointRel = base.path + "?sessionId=\(sid)"
        let payload: String
        switch variant {
        case .absolute: payload = endpointAbs
        case .relative: payload = endpointRel
        case .jsonUrl: payload = "{" + "\"url\":\"\(endpointRel)\"" + "}"
        case .jsonEndpoint_sessionIdLower:
            payload = "{" + "\"endpoint\":\"\(endpointRel)\",\"sessionId\":\"\(sid)\"" + "}"
        case .jsonEndpoint_sessionIDUpper:
            payload = "{" + "\"endpoint\":\"\(endpointRel)\",\"sessionID\":\"\(sid)\"" + "}"
        }
        let emit = {
            self.writeSSE(event: "endpoint", data: payload)
        }
        if delay <= 0 {
            emit()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { emit() }
        }
    }

    private func handleJSONRPCPost() {
        guard let url = request.url else { return }
        let hasSession = (url.query ?? "").contains("sessionId=")
        if hasSession == false {
            InMemoryHTTPSSEServer.basePOSTCount += 1
            if let status = InMemoryHTTPSSEServer.config.initialBasePostStatus {
                send(status: status, headers: ["Content-Type": "text/plain"], body: Data())
                return
            }
        } else {
            InMemoryHTTPSSEServer.sessionPOSTCount += 1
        }

        // Buffer body
        let body = request.httpBody ?? Data()
        let rpc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        // Ack 202 text/plain
        send(status: 202, headers: ["Content-Type": "text/plain"], body: Data())
        // Craft SSE message
        guard let id = rpc?["id"] else { return }
        let method = (rpc?["method"] as? String) ?? ""
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
                "result": ["tools": InMemoryHTTPSSEServer.config.tools]
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

    private func writeSSE(event: String, data: String) {
        var buf = Data()
        buf.append(Data("event: \(event)\n".utf8))
        for line in data.split(whereSeparator: \._isLineTerminator) {
            buf.append(Data("data: \(line)\n".utf8))
        }
        buf.append(Data("\n".utf8))
        SSEURLProtocol.sseResponder?(buf)
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        let res = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
