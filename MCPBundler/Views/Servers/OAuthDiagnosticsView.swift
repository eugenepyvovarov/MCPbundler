//
//  OAuthDiagnosticsView.swift
//  MCP Bundler
//
//  Shared diagnostics panel for inspecting OAuth discovery attempts.
//

import SwiftUI
import SwiftData

struct OAuthDiagnosticsView: View {
    var server: Server

    private var configuration: OAuthConfiguration? { server.oauthConfiguration }
    private var state: OAuthState? { server.oauthState }
    private var log: OAuthDiagnosticsLog { server.oauthDiagnostics }
    @State private var isRetryingDiscovery = false
    @State private var isSendingDiagnostics = false
    @State private var diagnosticsMessage: String?
    @State private var showAdvancedDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryCard
                advancedCard
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("OAuth Diagnostics")
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(title: "Status", value: server.oauthStatus.rawValue.capitalized)
                if let base = server.baseURL {
                    infoRow(title: "Base URL", value: base)
                }
                if let authEndpoint = configuration?.authorizationEndpoint?.absoluteString {
                    infoRow(title: "Authorization Endpoint", value: authEndpoint)
                }
                if let tokenEndpoint = configuration?.tokenEndpoint?.absoluteString {
                    infoRow(title: "Token Endpoint", value: tokenEndpoint)
                }
                if let registration = configuration?.registrationEndpoint?.absoluteString {
                    infoRow(title: "Registration Endpoint", value: registration)
                }
                if let resource = configuration?.resourceURI?.absoluteString {
                    infoRow(title: "Resource Indicator", value: resource)
                }
                if let rawAuthorization = latestAuthorizationHeader {
                    infoRow(title: "Authorization", value: rawAuthorization)
                        .textSelection(.enabled)
                }
                if let discovered = configuration?.discoveredAt {
                    infoRow(title: "Discovered", value: discovered.mcpShortDateTime())
                }
                if let lastRefresh = state?.lastTokenRefresh {
                    infoRow(title: "Last Refresh", value: lastRefresh.mcpShortDateTime())
                } else {
                    infoRow(title: "Last Refresh", value: "Not yet refreshed")
                }
                if let accessExpiryText = formattedAccessExpiry() {
                    infoRow(title: "Access Token Expires", value: accessExpiryText)
                }
                if let refreshExpiryText = formattedRefreshExpiry() {
                    infoRow(title: "Refresh Token Expires", value: refreshExpiryText)
                }
                if let refreshInactivity = state?.providerMetadata["refresh_inactivity_window_sec"],
                   let secs = Int(refreshInactivity), secs > 0 {
                    let hours = (secs + 1800) / 3600
                    infoRow(title: "Refresh Inactivity Window", value: "~\(hours)h (\(secs)s)")
                }
                if let cloudId = state?.cloudId, !cloudId.isEmpty {
                    infoRow(title: "Cloud ID", value: cloudId)
                }
            }

            HStack(spacing: 12) {
                Button {
                    retryDiscovery()
                } label: {
                    if isRetryingDiscovery {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                    Text(isRetryingDiscovery ? "Running Discovery…" : "Retry Discovery")
                }
                .disabled(isRetryingDiscovery)

                Button {
                    sendDiagnostics()
                } label: {
                    if isSendingDiagnostics {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                    Text(isSendingDiagnostics ? "Sending…" : "Send Diagnostics")
                }
                .disabled(isSendingDiagnostics)
            }

            if let diagnosticsMessage {
                Text(diagnosticsMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var latestAuthorizationHeader: String? {
        guard let project = server.project else { return nil }
        let entries = project.logs
            .filter { $0.category == "oauth.capabilities" && $0.message == "Updated request headers" }
            .sorted { $0.timestamp > $1.timestamp }
        for entry in entries {
            guard let data = entry.metadata,
                  let dict = try? JSONDecoder().decode([String: String].self, from: data),
                  let raw = dict["authorization_raw"],
                  !raw.isEmpty else { continue }
            return raw
        }
        return nil
    }

    private var advancedCard: some View {
        DisclosureGroup(isExpanded: $showAdvancedDetails) {
            VStack(alignment: .leading, spacing: 16) {
                stateSection
                Divider()
                discoverySection
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Text("Advanced Details")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow(title: "Active", value: (state?.isActive ?? false) ? "Yes" : "No")
            if let lastRefresh = state?.lastTokenRefresh {
                infoRow(title: "Last Refresh", value: lastRefresh.mcpShortDateTime())
            }
            infoRow(title: "Serialized State Size", value: "\(state?.serializedAuthState.count ?? 0) bytes")
            if let cloudId = state?.cloudId, !cloudId.isEmpty {
                infoRow(title: "Cloud ID", value: cloudId)
            }
            if let lastError = log.lastErrorDescription, !lastError.isEmpty {
                infoRow(title: "Last Error", value: lastError)
            }
            if let failedAt = log.lastRefreshFailedAt {
                infoRow(title: "Last Refresh Failure", value: failedAt.mcpShortDateTime())
            }
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if log.discoveryAttempts.isEmpty {
                Text("No discovery attempts recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.discoveryAttempts.sorted { $0.timestamp > $1.timestamp }) { attempt in
                    VStack(alignment: .leading, spacing: 6) {
                        let method = (attempt.httpMethod ?? "GET").uppercased()
                        Text("\(method) \(attempt.url.absoluteString)")
                            .font(.subheadline.weight(.semibold))
                            .textSelection(.enabled)

                        HStack {
                            if let code = attempt.statusCode {
                                Text("Status: \(code)")
                            } else {
                                Text("Status: n/a")
                            }
                            Spacer()
                            Text(attempt.timestamp.mcpShortDateTime())
                                .foregroundStyle(.secondary)
                        }

                        if let message = attempt.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if let headers = attempt.requestHeaders, !headers.isEmpty {
                            headerList(title: "Request Headers", headers: headers)
                        }

                        if let body = attempt.requestBodyPreview, !body.isEmpty {
                            previewBlock(title: "Request Body", text: body)
                        }

                        if let headers = attempt.responseHeaders, !headers.isEmpty {
                            headerList(title: "Response Headers", headers: headers)
                        }

                        if let preview = attempt.responseBodyPreview, !preview.isEmpty {
                            previewBlock(title: "Response Preview", text: preview)
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
                .padding(.top, 4)
            }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: - Expiry Helpers
    private func formattedAccessExpiry() -> String? {
        guard let meta = server.oauthState?.providerMetadata else { return nil }
        if let at = meta["access_expires_at"], let date = ISO8601DateFormatter().date(from: at) {
            return formatDateAndDelta(date)
        }
        if let secs = meta["access_expires_in_sec"], let s = Int(secs) {
            let date = Date().addingTimeInterval(TimeInterval(s))
            return formatDateAndDelta(date)
        }
        return nil
    }

    private func formattedRefreshExpiry() -> String? {
        guard let meta = server.oauthState?.providerMetadata else { return nil }
        if let at = meta["refresh_expires_at"], let date = ISO8601DateFormatter().date(from: at) {
            return formatDateAndDelta(date)
        }
        if let secs = meta["refresh_expires_in_sec"], let s = Int(secs) {
            let date = Date().addingTimeInterval(TimeInterval(s))
            return formatDateAndDelta(date)
        }
        return nil
    }

    private func formatDateAndDelta(_ date: Date) -> String {
        let abs = date.mcpShortDateTime()
        let remaining = Int(date.timeIntervalSinceNow)
        let suffix: String
        if remaining <= 0 {
            suffix = "expired"
        } else if remaining < 90 {
            suffix = "in \(remaining)s"
        } else if remaining < 3600 {
            suffix = "in \(remaining/60)m"
        } else if remaining < 48 * 3600 {
            suffix = "in \(remaining/3600)h"
        } else {
            suffix = "in ~\(remaining/86400)d"
        }
        return "\(abs) (\(suffix))"
    }

    @ViewBuilder
    private func headerList(title: String, headers: [String: String]) -> some View {
        if headers.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                ForEach(headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }), id: \.key) { key, value in
                    Text(verbatim: "\(key): \(value)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func previewBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func retryDiscovery() {
        guard !isRetryingDiscovery else { return }
        isRetryingDiscovery = true
        diagnosticsMessage = nil
        Task { @MainActor in
            await OAuthService.shared.runAuthDiscovery(server: server, wwwAuthenticate: nil)
            isRetryingDiscovery = false
            diagnosticsMessage = "Discovery retried \(Date().mcpShortDateTime())."
        }
    }

    private func sendDiagnostics() {
        guard !isSendingDiagnostics else { return }
        guard let project = server.project, project.modelContext != nil else {
            diagnosticsMessage = "Attach this server to a project to send diagnostics."
            return
        }
        if !server.isOAuthDebugLoggingEnabled {
            diagnosticsMessage = "Enable OAuth debug logging in the server editor to capture diagnostics."
            return
        }
        isSendingDiagnostics = true
        diagnosticsMessage = nil
        Task { @MainActor in
            var metadata: [String: String] = [
                "status": server.oauthStatus.rawValue,
                "discovery_attempts": "\(log.discoveryAttempts.count)"
            ]
            if let base = server.baseURL {
                metadata["base_url"] = base
            }
            if let authEndpoint = configuration?.authorizationEndpoint?.absoluteString {
                metadata["authorization_endpoint"] = authEndpoint
            }
            if let tokenEndpoint = configuration?.tokenEndpoint?.absoluteString {
                metadata["token_endpoint"] = tokenEndpoint
            }
            if let registration = configuration?.registrationEndpoint?.absoluteString {
                metadata["registration_endpoint"] = registration
            }
            if let resource = configuration?.resourceURI?.absoluteString {
                metadata["resource_indicator"] = resource
            }
            if let discovered = configuration?.discoveredAt {
                metadata["discovered_at"] = ISO8601DateFormatter().string(from: discovered)
            }
            if let lastRefresh = state?.lastTokenRefresh {
                metadata["last_refresh"] = ISO8601DateFormatter().string(from: lastRefresh)
            }
            if let meta = state?.providerMetadata, !meta.isEmpty {
                // include known TTL fields for remote triage
                let keys = [
                    "access_expires_at",
                    "access_expires_in_sec",
                    "refresh_expires_at",
                    "refresh_expires_in_sec",
                    "refresh_inactivity_window_sec"
                ]
                for key in keys {
                    if let v = meta[key] { metadata[key] = v }
                }
            }
            OAuthDebugLogger.log("User requested OAuth diagnostics snapshot",
                                 category: "oauth.diagnostics",
                                 server: server,
                                 metadata: metadata)
            diagnosticsMessage = "Diagnostics snapshot saved to project logs."
            isSendingDiagnostics = false
        }
    }
}
