//
//  OAuthStatusIndicator.swift
//  MCP Bundler
//
//  Shared pill indicator describing a server's OAuth connection state.
//

import SwiftUI

struct OAuthStatusIndicator: View {
    var status: OAuthStatus

    var body: some View {
        switch status {
        case .authorized:
            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .refreshing:
            Label("Refreshing", systemImage: "clock.arrow.circlepath").foregroundStyle(.yellow)
        case .unauthorized:
            Label("Sign-in required", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .error:
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
