//
//  OAuthTransportLogger.swift
//  MCP Bundler
//
//  Bridges Swift-log output from the HTTP transport into the OAuth debug log UI.
//

import Foundation
import SwiftData
import Logging

struct OAuthTransportLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    private let server: Server

    init(server: Server) {
        self.server = server
    }

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    func log(level: Logger.Level,
             message: Logger.Message,
             metadata additionalMetadata: Logger.Metadata?,
             source: String,
             file: String,
             function: String,
             line: UInt) {
        guard level >= .warning else { return }

        let messageText = message.description
        if level == .warning && messageText == "Unexpected content type: text/plain; charset=utf-8" {
            return
        }

        var payload: [String: String] = [
            "level": level.rawValue,
            "message": messageText
        ]

        let combinedMetadata = metadata.merging(additionalMetadata ?? [:], uniquingKeysWith: { _, new in new })
        for (key, value) in combinedMetadata {
            payload[key] = Self.stringify(value)
        }

        let isAuthChallenge = Self.isAuthChallenge(message: messageText, payload: payload)

        Task { @MainActor in
            if isAuthChallenge {
                OAuthService.shared.markAccessTokenInvalid(for: server)
                NotificationCenter.default.post(name: .oauthTransportAuthChallenge,
                                                object: nil,
                                                userInfo: ["serverID": String(describing: server.persistentModelID)])
            }
            if server.oauthStatus == .unauthorized || server.oauthStatus == .refreshing { return }
            OAuthDebugLogger.log("HTTP transport warning", category: "oauth.transport", server: server, metadata: payload)
        }
    }

    private static func stringify(_ value: Logger.Metadata.Value) -> String {
        switch value {
        case .string(let string):
            return string
        case .stringConvertible(let convertible):
            return convertible.description
        case .array(let array):
            return array.map(Self.stringify).joined(separator: ",")
        case .dictionary(let dictionary):
            return dictionary.map { "\($0.key)=\(Self.stringify($0.value))" }.sorted().joined(separator: ",")
        }
    }

    private static func isAuthChallenge(message: String, payload: [String: String]) -> Bool {
        let normalizedMessage = message.lowercased()
        if normalizedMessage.contains("401") &&
            (normalizedMessage.contains("unauthorized") || normalizedMessage.contains("authentication")) {
            return true
        }

        let statusKeys = ["status", "statusCode", "status_code", "http_status", "code"]
        for key in statusKeys {
            guard let value = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if value == "401" || value.hasPrefix("401 ") || value.hasSuffix(" 401") {
                return true
            }
        }

        if let detail = payload["detail"]?.lowercased(),
           detail.contains("401"),
           (detail.contains("unauthorized") || detail.contains("authentication")) {
            return true
        }

        return false
    }
}

extension Logger {
    static func oauthTransportLogger(for server: Server) -> Logger {
        Logger(label: "mcp.transport.http") { _ in
            OAuthTransportLogHandler(server: server)
        }
    }
}
