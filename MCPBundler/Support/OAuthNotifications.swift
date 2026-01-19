//
//  OAuthNotifications.swift
//  MCP Bundler
//
//  Shared identifiers for OAuth-related notifications and payload helpers.
//

import Foundation
import SwiftUI

extension Notification.Name {
    static let oauthToastRequested = Notification.Name("com.mcpbundler.oauth.toastRequested")
    static let oauthTokensRefreshed = Notification.Name("com.mcpbundler.oauth.tokensRefreshed")
    static let oauthTransportAuthChallenge = Notification.Name("com.mcpbundler.oauth.transportAuthChallenge")
}

struct OAuthToastPayload {
    enum Kind: String {
        case success
        case warning
        case info

        var style: ToastStyle {
            switch self {
            case .success: return .success
            case .warning: return .warning
            case .info: return .info
            }
        }
    }

    var title: String
    var message: String
    var alias: String
    var kind: Kind
    var shouldNotify: Bool

    init?(notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let title = userInfo["title"] as? String,
            let message = userInfo["message"] as? String,
            let alias = userInfo["alias"] as? String,
            let kindRaw = userInfo["kind"] as? String,
            let kind = Kind(rawValue: kindRaw)
        else {
            return nil
        }

        self.title = title
        self.message = message
        self.alias = alias
        self.kind = kind
        self.shouldNotify = (userInfo["notify"] as? Bool) ?? false
    }
}
