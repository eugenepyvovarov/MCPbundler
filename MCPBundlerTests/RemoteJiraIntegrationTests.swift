//
//  RemoteJiraIntegrationTests.swift
//  MCP Bundler
//
//  Integration test that exercises the Atlassian remote MCP server over HTTP+SSE.
//  Requires MCP_BUNDLER_SMOKE_TEST=1 plus ATLASSIAN_MCP_TOKEN (or ~/.mcp/atlassian_token).
//

import XCTest
@testable import MCPBundler

final class RemoteJiraIntegrationTests: XCTestCase {

    private let baseURL = URL(string: "https://mcp.atlassian.com/v1/sse")!
    private let originHeader = "https://mcp-bundler.maketry.xyz"

    func testAtlassianToolsList() async throws {
        guard ProcessInfo.processInfo.environment["MCP_BUNDLER_SMOKE_TEST"] == "1" else {
            throw XCTSkip("Set MCP_BUNDLER_SMOKE_TEST=1 plus ATLASSIAN_MCP_TOKEN (or ~/.mcp/atlassian_token) to run this integration test.")
        }
        var trace = SSETrace()
        let token = try requiredToken()
        let tokenAttachment = XCTAttachment(string: "Using token len=\(token.count)")
        tokenAttachment.lifetime = .keepAlways
        add(tokenAttachment)
        let session = makeSession()

        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(originHeader, forHTTPHeaderField: "Origin")

        trace.record("-- Opening SSE stream --")
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("Expected HTTPURLResponse")
            return
        }
        if httpResponse.statusCode != 200 {
            print("Initial SSE GET returned status", httpResponse.statusCode)
            var collected: [String] = []
            var count = 0
            var iterator = bytes.lines.makeAsyncIterator()
            while count < 20, let line = try await iterator.next() {
                collected.append(line)
                count += 1
            }
            let attachment = XCTAttachment(string: "SSE GET failed with status \(httpResponse.statusCode). First lines:\n\(collected.joined(separator: "\\n"))")
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Initial SSE GET returned status \(httpResponse.statusCode)")
            return
        }

        var iterator = bytes.lines.makeAsyncIterator()
        let endpointEvent: SSEEvent
        do {
            guard let next = try await nextSSEEvent(iterator: &iterator, trace: &trace) else {
                add(trace.makeAttachment(named: "SSE Trace (pre-endpoint)"))
                XCTFail("Did not receive endpoint event")
                return
            }
            endpointEvent = next
        } catch {
            print("Failed to read endpoint event", error)
            add(trace.makeAttachment(named: "SSE Trace (endpoint error)"))
            let attachment = XCTAttachment(string: "Failed to read endpoint event: \(error)")
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }

        let endpointAttachment = XCTAttachment(string: "Initial SSE event: event=\(endpointEvent.event ?? "<none>") data=\(endpointEvent.data)")
        endpointAttachment.lifetime = .keepAlways
        add(endpointAttachment)
        attach(event: endpointEvent, label: "endpoint", trace: trace)

        let sessionInfo: SessionInfo
        do {
            sessionInfo = try resolveSessionInfo(from: endpointEvent, base: baseURL)
        } catch {
            XCTFail("Unable to resolve session endpoint: \(error)")
            return
        }

        var postRequest = URLRequest(url: sessionInfo.endpointURL)
        postRequest.httpMethod = "POST"
        postRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        postRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        postRequest.setValue(originHeader, forHTTPHeaderField: "Origin")
        postRequest.setValue(sessionInfo.sessionHeader, forHTTPHeaderField: "Mcp-Session-Id")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "integration-tools-list",
            "method": "tools/list"
        ]
        postRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, postResponse) = try await session.data(for: postRequest)
        guard let httpPost = postResponse as? HTTPURLResponse else {
            XCTFail("Expected HTTPURLResponse for POST")
            return
        }
        XCTAssertEqual(httpPost.statusCode, 202)

        if let trace = httpPost.value(forHTTPHeaderField: "Atl-Traceid") {
            add(XCTAttachment(string: "atl-traceid: \(trace)"))
        }

        let messageEvent: SSEEvent
        do {
            guard let next = try await nextSSEEvent(iterator: &iterator, trace: &trace, timeout: 30) else {
                add(trace.makeAttachment(named: "SSE Trace (tools/list timeout)"))
                XCTFail("Timed out waiting for tools/list SSE message")
                return
            }
            messageEvent = next
        } catch {
            print("Failed to read message event", error)
            add(trace.makeAttachment(named: "SSE Trace (tools/list error)"))
            let attachment = XCTAttachment(string: "Failed to read message event: \(error)")
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }

        attach(event: messageEvent, label: "tools-list", trace: trace)

        let messageData = Data(messageEvent.data.utf8)
        let payloadAttachment = XCTAttachment(data: messageData, uniformTypeIdentifier: "public.json")
        payloadAttachment.lifetime = .keepAlways
        add(payloadAttachment)

        guard let messageString = String(data: messageData, encoding: .utf8) else {
            XCTFail("Failed to decode SSE message as UTF-8")
            return
        }

        XCTAssertTrue(messageString.contains("\"tools\""), "Expected tools key in SSE message")
    }

    private func requiredToken() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let found = env["ATLASSIAN_MCP_TOKEN"], !found.isEmpty {
            return found
        }
        let matching = env.keys.filter { $0.contains("ATLASSIAN") }
        add(XCTAttachment(string: "ATLASSIAN_* env keys visible: \(matching)"))
        let tokenFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mcp")
            .appendingPathComponent("atlassian_token", isDirectory: false)
        if let data = try? Data(contentsOf: tokenFile),
           let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            add(XCTAttachment(string: "Loaded token from \(tokenFile.path)"))
            return string
        }

        throw XCTSkip("ATLASSIAN_MCP_TOKEN not set (and no token file at \(tokenFile.path))")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    private func nextSSEEvent(iterator: inout AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator,
                              trace: inout SSETrace,
                              timeout: TimeInterval = 5) async throws -> SSEEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = try await readEvent(iterator: &iterator, trace: &trace) {
                return event
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func readEvent(iterator: inout AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator,
                          trace: inout SSETrace) async throws -> SSEEvent? {
        var currentEvent: String?
        var dataBuffer: [String] = []

        while let rawLine = try await iterator.next() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            trace.record(line.isEmpty ? "[heartbeat]" : "line: \(line)")
            if line.isEmpty {
                if !dataBuffer.isEmpty {
                    let event = SSEEvent(event: currentEvent, data: dataBuffer.joined(separator: "\n"))
                    trace.record("-- event delivered: \(event.debugDescription) --")
                    return event
                }
                currentEvent = nil
                continue
            }

            if line.hasPrefix(":") {
                continue
            }
            if line.lowercased().hasPrefix("event:") {
                currentEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if line.lowercased().hasPrefix("data:") {
                let value = line.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                dataBuffer.append(String(value))
                if (currentEvent?.lowercased() ?? "") == "endpoint" {
                    let event = SSEEvent(event: currentEvent, data: dataBuffer.joined(separator: "\n"))
                    trace.record("-- event delivered (endpoint immediate): \(event.debugDescription) --")
                    return event
                }
            }
        }

        if !dataBuffer.isEmpty {
            let event = SSEEvent(event: currentEvent, data: dataBuffer.joined(separator: "\n"))
            trace.record("-- event delivered (EOF): \(event.debugDescription) --")
            return event
        }
        return nil
    }

    private func attach(event: SSEEvent, label: String, trace: SSETrace) {
        var body = "label=\(label)\nevent=\(event.event ?? "<none>")\n"
        let dataPreviewLimit = 4096
        if event.data.count > dataPreviewLimit {
            let prefix = event.data.prefix(dataPreviewLimit)
            body.append("data=\(prefix)…\n")
        } else {
            body.append("data=\(event.data)\n")
        }
        let attachment = XCTAttachment(string: body)
        attachment.name = "SSE Event (\(label))"
        attachment.lifetime = .keepAlways
        add(attachment)
        let traceAttachmentName = "SSE Trace snapshot (\(label))"
        add(trace.makeAttachment(named: traceAttachmentName))
    }

    private func resolveSessionInfo(from event: SSEEvent, base: URL) throws -> SessionInfo {
        let raw = event.data
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let endpoint = json["url"] as? String ?? json["endpoint"] as? String,
               let url = URL(string: endpoint, relativeTo: base)?.absoluteURL {
                let sessionId = json["sessionId"] as? String ?? json["sessionID"] as? String
                return SessionInfo(endpointURL: url, sessionHeader: sessionId ?? url.sessionIDQueryValue())
            }
        }

        if let absolute = URL(string: raw, relativeTo: base)?.absoluteURL {
            return SessionInfo(endpointURL: absolute, sessionHeader: absolute.sessionIDQueryValue())
        }

        throw SessionResolutionError.unexpectedPayload(raw)
    }

    private struct SessionInfo {
        let endpointURL: URL
        let sessionHeader: String
    }

    private struct SSEEvent {
        let event: String?
        let data: String
        fileprivate var debugDescription: String {
            "event=\(event ?? "<none>")\ndata=\(data)"
        }
    }

    private enum SessionResolutionError: LocalizedError {
        case unexpectedPayload(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedPayload(let payload):
                return "Unexpected SSE endpoint payload: \(payload)"
            }
        }
    }
}

private extension URL {
    func sessionIDQueryValue() -> String {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name.lowercased() == "sessionid" }?.value ?? ""
    }
}

private struct SSETrace {
    private static let capacity = 200
    private var lines: [String] = []

    mutating func record(_ line: String) {
        if lines.count >= Self.capacity {
            lines.removeFirst()
        }
        lines.append("\(Date()): \(line)")
    }

    func makeAttachment(named name: String) -> XCTAttachment {
        let snapshot = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: snapshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
