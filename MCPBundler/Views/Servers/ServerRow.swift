//
//  ServerRow.swift
//  MCP Bundler
//
//  Display row for a server in the project detail list.
//

import SwiftUI

struct ServerRow: View {
    var server: Server

    var body: some View {
        HStack {
            Text(server.alias)
            Text(verbatim: "·")
            Text(server.kind == .local_stdio ? "Local STDIO" : "Remote HTTP/SSE")
                .foregroundStyle(.secondary)
            if server.kind == .remote_http_sse && server.usesOAuthAuthorization {
                Text(verbatim: "·")
                OAuthStatusIndicator(status: server.oauthStatus)
            }
            Spacer()
            HealthBadge(status: server.lastHealth)
        }
    }
}
