//
//  OAuthMigration.swift
//  MCP Bundler
//
//  Backfills OAuth scaffolding for legacy remote HTTP/SSE servers.
//

import Foundation
import SwiftData

enum OAuthMigration {
    static func performInitialBackfill(in container: ModelContainer, clock: () -> Date = Date.init) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Server>()
        let allServers = try context.fetch(descriptor)
        let remoteServers = allServers.filter { $0.kind == .remote_http_sse }

        var didMutate = false
        let now = clock()

        for server in remoteServers {
            if server.oauthConfiguration == nil {
                let configuration = OAuthConfiguration(server: server,
                                                       authorizationEndpoint: nil,
                                                       tokenEndpoint: nil,
                                                       registrationEndpoint: nil,
                                                       jwksEndpoint: nil,
                                                       scopes: [],
                                                       clientId: nil,
                                                       clientSecret: nil,
                                                       usePKCE: true,
                                                       resourceURI: nil,
                                                       discoveredAt: now,
                                                       metadataVersion: "2025-06-18")
                context.insert(configuration)
                server.oauthConfiguration = configuration
                didMutate = true
            }

            if server.oauthState == nil {
                let state = OAuthState(server: server,
                                       serializedAuthState: Data(),
                                       lastTokenRefresh: nil,
                                       isActive: false,
                                       keychainItemName: nil)
                context.insert(state)
                server.oauthState = state
                didMutate = true
            }

            if server.oauthStatus == .error {
                // Preserve prior failure state; otherwise reset to unauthorised for clarity.
                continue
            }

            if server.oauthStatus != .authorized {
                server.oauthStatus = .unauthorized
            }
        }

        if didMutate {
            try context.save()
        }
    }
}
