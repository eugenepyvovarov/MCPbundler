//
//  ServerDetailSheet.swift
//  MCP Bundler
//
//  Detail editor for an existing server configuration.
//

import SwiftUI
import SwiftData
import MCP

struct ServerDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.stdiosessionController) private var stdiosessionController

    @State private var isTesting = false
    @State private var testResult: HealthStatus
    @State private var errorText: String?
    @State private var persistenceError: String?
    @State private var isPerformingOAuthAction = false
    @State private var showOAuthDiagnostics = false
    @State private var oauthActionMessage: String?
    @State private var useManualOAuthClient: Bool
    @State private var manualClientId: String
    @State private var manualClientSecret: String
    @State private var manualPreset: ManualHeaderPreset
    @State private var manualCustomHeaderName: String
    @State private var showManualValue: Bool
    @State private var signInMode: SignInMode
    @State private var automaticAdvancedExpanded: Bool
    @State private var basicsSectionExpanded: Bool
    @State private var signInSectionExpanded: Bool
    @State private var connectionSectionExpanded: Bool
    @State private var recentLogs: [LogEntry] = []
    private let columnLabelWidth: CGFloat = 70
    private let statusDetailWidth: CGFloat = 260
    private let actionColumnWidth: CGFloat = 150
    @State private var selectedTab: ServerEditorTab = .basics
    private let recentLogAnchorID = "recentLogBottom"

    private enum SignInMode: String, CaseIterable, Identifiable {
        case none
        case automatic
        case manual
        var id: String { rawValue }
    }

    private static func locateManualCredentialHeader(on server: Server) -> HeaderBinding? {
        if let marked = server.headers.first(where: { $0.keychainRef == HeaderBinding.manualCredentialMarker }) {
            return marked
        }
        return server.headers.first(where: { $0.valueSource == .plain && isLikelyManualHeaderName($0.header) })
    }

    private static func isLikelyManualHeaderName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "authorization" || normalized == "x-api-key" { return true }
        if normalized.hasPrefix("x-") && normalized.contains("token") { return true }
        return false
    }

    private enum ManualHeaderPreset: String, CaseIterable, Identifiable {
        case bearer
        case basic
        case apiKey
        case custom
        var id: String { rawValue }
    }

    var server: Server

    init(server: Server) {
        self.server = server
        self._testResult = State(initialValue: server.lastHealth)
        let existingId = server.oauthConfiguration?.clientId ?? ""
        let existingSecret = server.oauthConfiguration?.clientSecret ?? ""
        self._useManualOAuthClient = State(initialValue: !existingId.isEmpty && (server.oauthConfiguration?.registrationEndpoint == nil))
        self._manualClientId = State(initialValue: existingId)
        self._manualClientSecret = State(initialValue: existingSecret)
        let manualHeader = ServerDetailSheet.locateManualCredentialHeader(on: server)
        if let manualHeader, manualHeader.keychainRef != HeaderBinding.manualCredentialMarker {
            manualHeader.keychainRef = HeaderBinding.manualCredentialMarker
        }
        let resolvedPreset = ServerDetailSheet.resolveManualPreset(for: manualHeader)
        self._manualPreset = State(initialValue: resolvedPreset)
        self._manualCustomHeaderName = State(initialValue: manualHeader?.header ?? "Authorization")
        self._showManualValue = State(initialValue: false)
        let hasOAuthHeader = server.usesOAuthAuthorization
        let defaultSignInMode: SignInMode
        if hasOAuthHeader {
            defaultSignInMode = .automatic
        } else if manualHeader != nil {
            defaultSignInMode = .manual
        } else {
            defaultSignInMode = .none
        }
        self._signInMode = State(initialValue: defaultSignInMode)
        self._automaticAdvancedExpanded = State(initialValue: false)
        let isRemote = server.kind == .remote_http_sse
        self._basicsSectionExpanded = State(initialValue: true)
        self._signInSectionExpanded = State(initialValue: isRemote)
        let shouldExpandConnection = server.lastHealth == .degraded || server.lastHealth == .unhealthy
        self._connectionSectionExpanded = State(initialValue: isRemote && shouldExpandConnection)
        self._selectedTab = State(initialValue: .basics)
    }

    private var basicsSubtitleText: String {
        guard let raw = server.baseURL, !raw.isEmpty else {
            return "Set the MCP base URL"
        }
        if let url = URL(string: raw), let host = url.host {
            return host
        }
        return raw
    }

    private var signInSubtitleText: String {
        switch signInMode {
        case .manual:
            return "Manual access"
        case .none:
            return "No authentication"
        case .automatic:
            switch displayOAuthStatus {
            case .authorized:
                return "Signed in"
            case .refreshing:
                return "Refreshing session"
            case .unauthorized:
                return "Sign-in required"
            case .error:
                return "Needs attention"
            }
        }
    }

    private var manualCredentialHeader: HeaderBinding? {
        ServerDetailSheet.locateManualCredentialHeader(on: server)
    }

    private var generalHeaders: [HeaderBinding] {
        server.headers.filter { $0.keychainRef != HeaderBinding.manualCredentialMarker && $0.valueSource != .oauthAccessToken }
    }

    private var connectionSubtitleText: String {
        switch server.lastHealth {
        case .healthy:
            if let lastCheckedAt = server.lastCheckedAt {
            return "Last check \(lastCheckedAt.mcpShortDateTime())"
            }
            return "Last check succeeded"
        case .degraded:
            return "Partial issues detected"
        case .unhealthy:
            return "Connection failed"
        case .unknown:
            return "No recent checks"
        }
    }

    private var remoteBasicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Alias")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("alias", text: Binding(
                    get: { server.alias },
                    set: { server.alias = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            }
            if let aliasValidationMessage {
                Text(aliasValidationMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Text("Kind")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding.constant(server.kind)) {
                    Text("Local STDIO").tag(ServerKind.local_stdio)
                    Text("Remote HTTP/SSE").tag(ServerKind.remote_http_sse)
                }
                .pickerStyle(.segmented)
                .disabled(true)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Base URL")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("https://api.example.com/mcp", text: Binding(
                    get: { server.baseURL ?? "" },
                    set: { server.baseURL = ServerURLNormalizer.normalizeOptional($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            }
            Text("Use the MCP endpoint your provider documents (paths like `/mcp` are preserved).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var localBasicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kind")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding.constant(server.kind)) {
                    Text("Local STDIO").tag(ServerKind.local_stdio)
                    Text("Remote HTTP/SSE").tag(ServerKind.remote_http_sse)
                }
                .pickerStyle(.segmented)
                .disabled(true)
            }

            HStack {
                Text("Alias")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("alias", text: Binding(
                    get: { server.alias },
                    set: { server.alias = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            }
            if let aliasValidationMessage {
                Text(aliasValidationMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            localEditor
        }
        .padding(12)
    }

    private var remoteSignInSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $signInMode) {
                Text("No Authentication").tag(SignInMode.none)
                Text("Automatic (OAuth)").tag(SignInMode.automatic)
                Text("Manual Access Key").tag(SignInMode.manual)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            switch signInMode {
            case .automatic:
                automaticSignInCard
            case .manual:
                manualAccessKeyCard
            case .none:
                noAuthCard
            }
        }
        .onChange(of: signInMode) { _, newValue in
            switch newValue {
            case .automatic:
                ensureOAuthAuthorizationHeader()
                removeManualCredentialHeader()
            case .manual:
                removeOAuthAuthorizationHeader()
                _ = ensureManualPrimaryHeader()
                syncManualPresetState()
                showManualValue = false
            case .none:
                clearCredentialArtifacts()
                manualPreset = .bearer
                manualCustomHeaderName = "Authorization"
                showManualValue = false
                useManualOAuthClient = false
                oauthActionMessage = nil
            }
        }
    }

    private var recentLogsSection: some View {
        GroupBox("Recent Logs") {
            if recentLogs.isEmpty {
                ZStack {
                    Text("No recent logs recorded for this server.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(recentLogs.enumerated()), id: \.offset) { index, entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(entry.level.rawValue.uppercased())
                                        .font(.caption.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(levelColor(for: entry.level).opacity(0.16))
                                        .foregroundStyle(levelColor(for: entry.level))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(entry.message)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(recentLogAnchorID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 160, maxHeight: 240)
                    .onChange(of: recentLogs.count) { _, _ in
                        withAnimation { scrollProxy.scrollTo(recentLogAnchorID, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func levelColor(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .info: return .blue
        case .debug: return .gray
        }
    }

    @MainActor
    private func reloadRecentLogs() {
        guard let project = server.project else {
            recentLogs = []
            return
        }
        let trimmedAlias = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedAliasForLogs(trimmedAlias)
        let aliasLower = trimmedAlias.lowercased()
        let normalizedLower = normalized.lowercased()
        var descriptor = FetchDescriptor<LogEntry>(sortBy: [SortDescriptor(\LogEntry.timestamp, order: .reverse)])
        descriptor.fetchLimit = 200
        if let fetched = try? modelContext.fetch(descriptor) {
            let serverPrefix = "server.\(normalized)"
            let setupPrefix = "setup.\(normalized)"
            let serverPrefixLower = serverPrefix.lowercased()
            let setupPrefixLower = setupPrefix.lowercased()
            let decoder = JSONDecoder()

            func matches(_ entry: LogEntry) -> Bool {
                guard entry.project == project else { return false }
                let categoryLower = entry.category.lowercased()
                if categoryLower.hasPrefix(serverPrefixLower) || categoryLower.hasPrefix(setupPrefixLower) {
                    return true
                }

                let messageLower = entry.message.lowercased()
                if messageLower.contains("alias=\(aliasLower)") || messageLower.contains("alias=\"\(aliasLower)") {
                    return true
                }
                if !normalizedLower.isEmpty, (messageLower.contains("alias=\(normalizedLower)") || messageLower.contains("alias=\"\(normalizedLower)")) {
                    return true
                }

                if let metadata = entry.metadata,
                   let decoded = try? decoder.decode([String: String].self, from: metadata) {
                    if let metaAlias = decoded["alias"]?.lowercased(), metaAlias == aliasLower || metaAlias == normalizedLower {
                        return true
                    }
                    if let metaAlias = decoded["alias_normalized"]?.lowercased(), metaAlias == normalizedLower || metaAlias == aliasLower {
                        return true
                    }
                }

                return false
            }

            var filtered = fetched.filter(matches)
            filtered.sort { $0.timestamp < $1.timestamp }
            if filtered.count > 50 {
                filtered = Array(filtered.suffix(50))
            }
            recentLogs = filtered
        } else {
            recentLogs = []
        }
    }

    private func normalizedAliasForLogs(_ alias: String) -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unnamed" }
        return trimmed.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
    }


    private var remoteConnectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button("Test Connection", action: testConnection)
                    .disabled(!server.isEnabled || aliasValidationMessage != nil || isPerformingOAuthAction)
                    .frame(minWidth: actionColumnWidth, alignment: .trailing)
                HealthBadge(status: isTesting ? .unknown : testResult)
                Spacer()
                if let lastCheckedAt = server.lastCheckedAt {
                    Text("Checked \(lastCheckedAt.mcpShortDateTime())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
            }

            capabilityListContent
        }
    }

    private var aliasValidationMessage: String? {
        let trimmed = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Alias is required." }
        guard trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return "Alias can include letters (A-Z or a-z), numbers, underscores, and hyphens."
        }
        guard let project = server.project else { return nil }
        let conflict = project.servers.contains { candidate in
            candidate !== server && candidate.alias.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return conflict ? "Alias already exists in this project." : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    configurationSection
                    if shouldShowRecentLogs {
                        recentLogsSection
                    }
                    if let persistenceError {
                        Text(persistenceError)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { saveAndDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { reloadRecentLogs() }
        .onChange(of: server.alias) { _, _ in reloadRecentLogs() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Server: \(server.alias)").font(.title2)
                Spacer()
                let folderDisabled = (server.folder?.isEnabled == false)
                Toggle(isOn: Binding(
                    get: { folderDisabled ? false : server.isEnabled },
                    set: { newValue in
                        if folderDisabled && newValue {
                            return
                        }
                        server.isEnabled = newValue
                        try? modelContext.save()
                        guard let project = server.project else { return }
                        let eventType: BundlerEvent.EventType = newValue ? .serverEnabled : .serverDisabled
                        Task { @MainActor in
                            try? await ProjectSnapshotCache.rebuildSnapshot(for: project)
                            BundlerEventService.emit(in: modelContext, project: project, servers: [server], type: eventType)
                            let serverIDSet: Set<PersistentIdentifier> = [server.persistentModelID]
                            await stdiosessionController?.reload(projectID: project.persistentModelID,
                                                                 serverIDs: serverIDSet)
                            if modelContext.hasChanges {
                                try? modelContext.save()
                            }
                        }
                    }
                )) {
                    Text((folderDisabled ? false : server.isEnabled) ? "Enabled" : "Disabled")
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(folderDisabled)
                .help(folderDisabled ? "Enable the folder to enable this server." : (server.isEnabled ? "Disable server" : "Enable server"))
            }
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        if server.kind == .local_stdio {
            localEditorTabs
        } else {
            remoteEditor
        }
    }

    private var shouldShowRecentLogs: Bool { selectedTab != .tools }

    // STDIO (local) servers: Basics | Tools tabs
    private var localEditorTabs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $selectedTab) {
                Text("Basics").tag(ServerEditorTab.basics)
                Text("Tools").tag(ServerEditorTab.tools)
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .basics:
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Basics") { localBasicsSection }
                        GroupBox("Status") { remoteStatusSummary }
                    }
                case .tools:
                    capabilityInfo
                case .auth:
                    // Not applicable for STDIO; fall back to basics
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Basics") { localBasicsSection }
                        GroupBox("Status") { remoteStatusSummary }
                    }
                }
            }
        }
        .onAppear { if selectedTab == .auth { selectedTab = .basics } }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("Test Connection", action: testConnection)
                .disabled(!server.isEnabled || aliasValidationMessage != nil)
            HealthBadge(status: isTesting ? .unknown : testResult)
            Spacer()
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
            }
        }
    }

    private func saveAndDismiss() {
        do {
            server.alias = server.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            try modelContext.save()
            persistenceError = nil
            if let project = server.project {
                let target = project
                Task { @MainActor in
                    try? await ProjectSnapshotCache.rebuildSnapshot(for: target)
                    BundlerEventService.emit(in: modelContext,
                                             project: target,
                                             servers: [server],
                                             type: .serverUpdated)
                    let projectID = target.persistentModelID
                    let serverID = server.persistentModelID
                    await stdiosessionController?.reload(projectID: projectID,
                                                         serverIDs: Set([serverID]))
                    if modelContext.hasChanges {
                        try? modelContext.save()
                    }
                }
            }
            dismiss()
        } catch {
            persistenceError = "Failed to save changes: \(error.localizedDescription)"
        }
    }

    private var capabilityInfo: some View {
        GroupBox("Tools") {
            capabilityListContent
        }
    }

    private var capabilityListContent: some View {
        let info = parseCapabilities()
        return VStack(alignment: .leading, spacing: 8) {
            if !server.isEnabled {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Server is disabled. Selected tools will be activated when the server is enabled.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if info.tools.isEmpty {
                Text("No tools available.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Tool Name")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Status")
                            .font(.headline)
                            .frame(width: 80)
                        Text("Actions")
                            .font(.headline)
                            .frame(width: 80)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(info.tools.enumerated()), id: \.element.name) { index, tool in
                        HStack {
                            Text(tool.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(server.isEnabled ? .primary : .secondary)

                            Toggle("", isOn: Binding(
                                get: {
                                    if server.includeTools.isEmpty {
                                        // Enable all tools by default
                                        server.includeTools = info.tools.map { $0.name }
                                        return server.includeTools.contains(tool.name)
                                    }
                                    return server.includeTools.contains(tool.name)
                                },
                                set: { newValue in
                                    if newValue {
                                        if !server.includeTools.contains(tool.name) {
                                            server.includeTools.append(tool.name)
                                        }
                                    } else {
                                        server.includeTools.removeAll { $0 == tool.name }
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .frame(width: 80)
                            .disabled(!server.isEnabled)

                            Button("Preview") {
                                showingToolDetail = tool
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(width: 80)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .opacity(server.isEnabled ? 1.0 : 0.7)

                        if index < info.tools.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            if let resources = info.resources, !resources.isEmpty {
                Divider()
                Text("Resources").font(.subheadline)
                ForEach(resources, id: \.name) { resource in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.name).bold()
                        if let description = resource.description, !description.isEmpty {
                            Text(description).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let prompts = info.prompts, !prompts.isEmpty {
                Divider()
                Text("Prompts").font(.subheadline)
                ForEach(prompts, id: \.name) { prompt in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.name).bold()
                        if let description = prompt.description, !description.isEmpty {
                            Text(description).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $showingToolDetail) { mcpTool in
            ToolDetailSheet(tool: Tool(
                name: mcpTool.name,
                description: mcpTool.description ?? "",
                inputSchema: mcpTool.inputSchema ?? .object([:]),
                annotations: mcpTool.annotations ?? Tool.Annotations(
                    title: nil,
                    readOnlyHint: nil,
                    destructiveHint: nil,
                    idempotentHint: nil,
                    openWorldHint: nil
                )
            ))
        }
    }

    @State private var showingToolDetail: MCPTool?

    private var localEditor: some View {
        LocalStdioConfigurationForm(
            layout: .labeled(width: columnLabelWidth),
            showEnvValues: false,
            execPath: Binding(
                get: { server.execPath ?? "" },
                set: { server.execPath = $0 }
            ),
            argumentsText: Binding(
                get: { server.args.joined(separator: " ") },
                set: { server.args = $0.split(separator: " ").map(String.init) }
            ),
            envVars: server.envOverrides.sorted { $0.position < $1.position },
            onAddEnvVar: addEnvOverride,
            onDeleteEnvVar: { env in
                if let idx = server.envOverrides.firstIndex(where: { $0 === env }) {
                    server.envOverrides.remove(at: idx)
                    server.envOverrides.normalizeEnvPositions()
                }
            }
        )
    }

    private var remoteEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $selectedTab) {
                Text("Basics").tag(ServerEditorTab.basics)
                Text("Auth").tag(ServerEditorTab.auth)
                Text("Tools").tag(ServerEditorTab.tools)
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .basics:
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Basics") { remoteBasicsSection }
                        GroupBox("Status") { remoteStatusSummary }
                    }
                case .auth:
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Sign-In Method") { remoteSignInSection }
                            .frame(maxWidth: .infinity)
                        advancedOptionsCard
                            .frame(maxWidth: .infinity)
                    }
                case .tools:
                    capabilityInfo
                }
            }
        }
        .onAppear {
            server.baseURL = ServerURLNormalizer.normalizeOptional(server.baseURL)
        }
        .sheet(isPresented: $showOAuthDiagnostics) {
            NavigationStack {
                OAuthDiagnosticsView(server: server)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showOAuthDiagnostics = false }
                        }
                    }
            }
        }
    }

    // Status summary (Connection status + Auth + Tools) for Basics tab.
    private var remoteStatusSummary: some View {
        // Fixed-width columns: label | value | detail | action
        let labelW: CGFloat = columnLabelWidth
        let valueW: CGFloat = 160
        return VStack(alignment: .leading, spacing: 8) {
            // Status row
            HStack(spacing: 12) {
                Text("Status")
                    .frame(width: labelW, alignment: .trailing)
                    .foregroundStyle(.secondary)
                HealthBadge(status: isTesting ? .unknown : testResult)
                    .frame(width: valueW, alignment: .leading)
                Group {
                    if let last = server.lastCheckedAt {
                        Text("Checked \(last.mcpShortDateTime())")
                    } else {
                        Text("No recent checks")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button("Test Connection", action: testConnection)
                    .disabled(!server.isEnabled || aliasValidationMessage != nil || isPerformingOAuthAction)
                    .frame(minWidth: actionColumnWidth, alignment: .trailing)
            }

            if let errorText {
                // Align error message to the detail (3rd) column for visual consistency
                HStack(spacing: 12) {
                    // Empty placeholders to occupy label + value columns
                    Text("")
                        .frame(width: labelW, alignment: .trailing)
                    Text("")
                        .frame(width: valueW, alignment: .leading)
                    // Error text in the detail column
                    Text(errorText)
                        .foregroundStyle(.red)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    // Reserve space for the action column
                    Spacer()
                        .frame(minWidth: actionColumnWidth)
                }
            }

            // Auth row
            HStack(spacing: 12) {
                Text("Auth")
                    .frame(width: labelW, alignment: .trailing)
                    .foregroundStyle(.secondary)
                authBadge
                    .frame(width: valueW, alignment: .leading)
                Group { if let detail = authDetailText { Text(detail) } }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let action = authActionButton { action.frame(minWidth: actionColumnWidth, alignment: .trailing) }
            }

            // Tools row
            HStack(spacing: 12) {
                Text("Tools")
                    .frame(width: labelW, alignment: .trailing)
                    .foregroundStyle(.secondary)
                let counts = toolCounts()
                Text("\(counts.enabled) turned on / \(counts.total) total")
                    .frame(width: valueW, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }

    private var authBadge: some View {
        // If no auth configured at all, indicate that neutrally and show no action button
        if server.usesManualCredentials {
            return AnyView(Label("Manual access", systemImage: "key.fill").foregroundStyle(Color.accentColor))
        }
        if !server.usesOAuthAuthorization {
            return AnyView(Label("Without authorization", systemImage: "minus.circle").foregroundStyle(.secondary))
        }
        // Map OAuthStatus to a Health-like badge appearance
        let mapped: HealthStatus
        switch server.oauthStatus {
        case .authorized: mapped = .healthy
        case .refreshing: mapped = .degraded
        case .unauthorized, .error: mapped = .unhealthy
        }
        // Render with custom label text but HealthBadge colors/icons
        return AnyView(Group {
            switch mapped {
            case .healthy:
                Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .degraded:
                Label("Refreshing", systemImage: "clock.arrow.circlepath").foregroundStyle(.yellow)
            case .unhealthy:
                let label = (server.oauthStatus == .unauthorized) ? "Sign-in required" : "Needs attention"
                Label(label, systemImage: server.oauthStatus == .unauthorized ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .unknown:
                Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
        })
    }

    private var advancedOptionsCard: some View {
        CollapsibleCard(
            isExpanded: $automaticAdvancedExpanded,
            iconName: "slider.horizontal.3",
            title: "Advanced Options",
            subtitle: "OAuth diagnostics, headers, environment overrides."
        ) {
            advancedOptionsContent
        }
    }

    @ViewBuilder
    private var advancedOptionsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable OAuth debug logging", isOn: Binding(
                get: { server.isOAuthDebugLoggingEnabled },
                set: { server.isOAuthDebugLoggingEnabled = $0 }
            ))
            .font(.footnote)
            .help("Record verbose OAuth activity in project logs to troubleshoot discovery, sign-in, refresh, and capability fetch steps.")

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Additional Headers").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { addHeader() } label: { Label("Add Header", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                if generalHeaders.isEmpty {
                    Text("No additional headers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HeaderEditor(headers: generalHeaders, onDelete: { header in
                        header.modelContext?.delete(header)
                        if let idx = server.headers.firstIndex(where: { $0 === header }) {
                            server.headers.remove(at: idx)
                        }
                    }, showValues: false, allowsOAuthSource: false)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Environment Overrides").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { addEnvOverride() } label: { Label("Add Variable", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                if server.envOverrides.isEmpty {
                    Text("No environment overrides.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    EnvEditor(envVars: server.envOverrides.sorted { $0.position < $1.position }, onDelete: { env in
                        if let idx = server.envOverrides.firstIndex(where: { $0 === env }) {
                            server.envOverrides.remove(at: idx)
                            server.envOverrides.normalizeEnvPositions()
                        }
                    }, showValues: false)
                }
            }
        }
    }

    private func testConnection() {
        guard server.project != nil else { return }
        guard aliasValidationMessage == nil else { return }
        isTesting = true
        testResult = .unknown
        errorText = nil

        server.baseURL = ServerURLNormalizer.normalizeOptional(server.baseURL)

        Task { @MainActor in
            defer {
                isTesting = false
                reloadRecentLogs()
            }
            do {
                let providerServer: Server
                if server.kind == .remote_http_sse {
                    guard applyManualCredentialsToServer() else {
                        throw MCPError.internalError("Manual OAuth client credentials are required.")
                    }
                    providerServer = server
                } else {
                    providerServer = server
                }

                let provider = CapabilitiesService.provider(for: providerServer)
                let capabilities = try await provider.fetchCapabilities(for: providerServer)
                if let data = try? JSONEncoder().encode(capabilities) {
                    server.replaceCapabilityCache(payload: data, generatedAt: Date(), in: modelContext)
                }
                server.lastHealth = .healthy
                server.lastCheckedAt = Date()
                testResult = .healthy
                errorText = nil

                if let project = server.project {
                    do {
                        try modelContext.save()
                        persistenceError = nil
                        try? await ProjectSnapshotCache.rebuildSnapshot(for: project)
                        BundlerEventService.emit(in: modelContext,
                                                 project: project,
                                                 servers: [server],
                                                 type: .serverUpdated)
                        let projectID = project.persistentModelID
                        let serverID = server.persistentModelID
                        await stdiosessionController?.reload(projectID: projectID,
                                                             serverIDs: Set([serverID]))
                        if modelContext.hasChanges {
                            try? modelContext.save()
                        }
                    } catch {
                        persistenceError = "Failed to persist capabilities: \(error.localizedDescription)"
                    }
                }
            } catch {
                testResult = .unhealthy
                server.lastHealth = .unhealthy
                server.lastCheckedAt = Date()
                errorText = describeError(error)
            }
        }
    }

    private func addEnvOverride() {
        let nextPosition = server.envOverrides.nextEnvPosition()
        let env = EnvVar(server: server,
                         key: "",
                         valueSource: .plain,
                         plainValue: "",
                         position: nextPosition)
        server.envOverrides.append(env)
    }

    private func addHeader() {
        let header = HeaderBinding(server: server, header: "", valueSource: .plain, plainValue: "")
        server.headers.append(header)
    }

    private var requiresOAuth: Bool {
        guard signInMode == .automatic else { return false }
        return server.usesOAuthAuthorization
    }

    private var oauthAuthorizationHeader: HeaderBinding? {
        server.headers.first { $0.valueSource == .oauthAccessToken }
    }

    private func ensureOAuthAuthorizationHeader() {
        guard oauthAuthorizationHeader == nil else { return }
        let header = HeaderBinding(
            server: server,
            header: "Authorization",
            valueSource: .oauthAccessToken,
            plainValue: nil
        )
        server.headers.append(header)
    }

    private func removeOAuthAuthorizationHeader() {
        let oauthHeaders = server.headers.filter { $0.valueSource == .oauthAccessToken }
        for header in oauthHeaders {
            header.modelContext?.delete(header)
            if let idx = server.headers.firstIndex(where: { $0 === header }) {
                server.headers.remove(at: idx)
            }
        }
    }

    private func removeManualCredentialHeader() {
        guard let header = manualCredentialHeader else { return }
        header.modelContext?.delete(header)
        if let idx = server.headers.firstIndex(where: { $0 === header }) {
            server.headers.remove(at: idx)
        }
    }

    private func clearCredentialArtifacts() {
        removeOAuthAuthorizationHeader()
        removeManualCredentialHeader()
    }

    @discardableResult
    private func ensureManualPrimaryHeader() -> HeaderBinding {
        if let header = manualPrimaryHeader {
            if header.keychainRef != HeaderBinding.manualCredentialMarker {
                header.keychainRef = HeaderBinding.manualCredentialMarker
            }
            return header
        }
        let header = HeaderBinding(server: server, header: "Authorization", valueSource: .plain, plainValue: "")
        header.keychainRef = HeaderBinding.manualCredentialMarker
        server.headers.insert(header, at: 0)
        return header
    }

    private var manualPrimaryHeader: HeaderBinding? {
        manualCredentialHeader
    }

    // Removed: manualAdditionalHeaders (use Advanced section instead)

    private static func resolveManualPreset(for header: HeaderBinding?) -> ManualHeaderPreset {
        guard let header else { return .bearer }
        let name = header.header.lowercased()
        let value = (header.plainValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "authorization" {
            if value.hasPrefix("Bearer ") {
                return .bearer
            }
            if value.hasPrefix("Basic ") {
                return .basic
            }
            return .custom
        }
        if name == "x-api-key" {
            return .apiKey
        }
        return .custom
    }

    private func manualToken(for header: HeaderBinding, preset: ManualHeaderPreset) -> String {
        let value = header.plainValue ?? ""
        switch preset {
        case .bearer:
            return value.hasPrefix("Bearer ") ? String(value.dropFirst("Bearer ".count)) : value
        case .basic:
            return value.hasPrefix("Basic ") ? String(value.dropFirst("Basic ".count)) : value
        case .apiKey, .custom:
            return value
        }
    }

    private func applyManualPreset(_ preset: ManualHeaderPreset, token rawToken: String) {
        let header = ensureManualPrimaryHeader()
        let trimmedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        header.keychainRef = HeaderBinding.manualCredentialMarker
        switch preset {
        case .bearer:
            header.header = "Authorization"
            header.plainValue = trimmedToken.isEmpty ? "" : "Bearer \(trimmedToken)"
            manualCustomHeaderName = header.header
        case .basic:
            header.header = "Authorization"
            header.plainValue = trimmedToken.isEmpty ? "" : "Basic \(trimmedToken)"
            manualCustomHeaderName = header.header
        case .apiKey:
            header.header = "X-API-Key"
            header.plainValue = trimmedToken
            manualCustomHeaderName = header.header
        case .custom:
            let name = manualCustomHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
            header.header = name.isEmpty ? "X-Custom-Header" : name
            header.plainValue = trimmedToken
            manualCustomHeaderName = header.header
        }
    }

    private func syncManualPresetState() {
        let header = ensureManualPrimaryHeader()
        manualPreset = ServerDetailSheet.resolveManualPreset(for: header)
        if manualPreset == .custom {
            manualCustomHeaderName = ""
        } else {
            manualCustomHeaderName = header.header
        }
    }

    private var manualValueBinding: Binding<String> {
        Binding(
            get: {
                let header = ensureManualPrimaryHeader()
                let preset = manualPreset
                return manualToken(for: header, preset: preset)
            },
            set: { newValue in
                applyManualPreset(manualPreset, token: newValue)
            }
        )
    }

    private var automaticSignInCard: some View {
        let status = displayOAuthStatus
        let headerConfigured = server.usesOAuthAuthorization

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                authenticationBadge(for: status)
                if let lastRefresh = server.oauthState?.lastTokenRefresh {
                    Text("Last refreshed \(lastRefresh.mcpShortDateTime())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPerformingOAuthAction {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }

            if headerConfigured {
                Text(statusLine(for: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use manual OAuth client credentials (required for GitHub)", isOn: $useManualOAuthClient)
                    .font(.footnote)

                if useManualOAuthClient {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Client ID", text: $manualClientId)
                            .textFieldStyle(.roundedBorder)

                        SecureField("Client Secret (optional)", text: $manualClientSecret)
                            .textFieldStyle(.roundedBorder)

                        Text("GitHub MCP servers need the Client ID/Secret from your developer settings because they do not support dynamic registration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Tokens and client credentials stay on this Mac inside SwiftData. A secure storage upgrade is planned in a future release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    let primary = automaticPrimaryAction(for: status)
                    Button(primary.title) { primary.action?() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!headerConfigured || !primary.enabled || primary.action == nil)

                    Button("Reset saved sign-in", role: .destructive) { disconnectOAuth() }
                        .disabled(isPerformingOAuthAction)

                    Button("Open Diagnostics") { showOAuthDiagnostics = true }
                        .disabled(isPerformingOAuthAction)

                    Spacer(minLength: 0)
                }

                if let message = oauthActionMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if server.oauthStatus == .error {
                    Text("OAuth encountered an error. Try signing in again or review diagnostics.")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

            } else {
                Text("Add an Authorization header sourced from OAuth tokens to enable automatic sign-in and background refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Enable Authorization Header") {
                    ensureOAuthAuthorizationHeader()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func statusLine(for status: OAuthStatus) -> String {
        switch status {
        case .authorized:
            return "Signed in with saved OAuth credentials."
        case .refreshing:
            return "Refreshing OAuth session..."
        case .unauthorized:
            return "Sign-in required."
        case .error:
            return "OAuth encountered an error."
        }
    }

    private var manualAccessKeyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provide headers or access keys shared by your provider. Values remain local to this Mac and are masked by default.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Primary Header")
                    .font(.subheadline.weight(.semibold))

                // Preset selection rows (radio + explanation)
                manualPresetChoiceRow(.bearer, title: "Authorization · Bearer", help: "Adds Bearer <token> to Authorization")
                manualPresetChoiceRow(.basic,  title: "Authorization · Basic",  help: "Adds Basic <token> to Authorization")
                manualPresetChoiceRow(.apiKey,  title: "X-API-Key",              help: "Sends X-API-Key: <value>")
                manualPresetChoiceRow(.custom,  title: "Custom",                  help: "Choose any header name and value")

                // Single editable key=value pair reflecting the selected preset
                HStack(spacing: 8) {
                    // KEY column
                    VStack(alignment: .leading, spacing: 4) {
                        Text("KEY")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if manualPreset == .custom {
                            TextField("Header Name", text: $manualCustomHeaderName)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .frame(minWidth: 180)
                        } else {
                            TextField("Header", text: .constant(manualPreset == .apiKey ? "X-API-Key" : "Authorization"))
                                .textFieldStyle(.roundedBorder)
                                .disabled(true)
                                .frame(minWidth: 180)
                        }
                    }

                    Text("=")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    // VALUE column
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VALUE")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if showManualValue {
                                TextField("Value", text: manualValueBinding)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Value", text: .constant(String(repeating: "*", count: max(manualValueBinding.wrappedValue.count, 1))))
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                            }
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showManualValue.toggle() }
                            } label: {
                                Image(systemName: showManualValue ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(showManualValue ? "Hide value" : "Show value")
                        }
                    }
                }

            }

            // Additional headers removed from Manual Access section.
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear {
            syncManualPresetState()
        }
        .onChange(of: manualPreset) { oldValue, newValue in
            let header = ensureManualPrimaryHeader()
            let token = manualToken(for: header, preset: oldValue)
            if newValue == .custom { manualCustomHeaderName = "" }
            applyManualPreset(newValue, token: token)
        }
        .onChange(of: manualCustomHeaderName) { _, newValue in
            guard manualPreset == .custom else { return }
            let header = ensureManualPrimaryHeader()
            let sanitized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = sanitized.isEmpty ? "X-Custom-Header" : sanitized
            if header.header != resolved {
                header.header = resolved
            }
        }
    }

    private var manualPresetHelpText: String {
        switch manualPreset {
        case .bearer: return "We’ll send Authorization: Bearer … with the value you enter."
        case .basic:  return "We’ll send Authorization: Basic … with the value you enter."
        case .apiKey: return "We’ll send X-API-Key: <value>."
        case .custom: return "Choose any header name and value required by your provider."
        }
    }

    @ViewBuilder
    private func manualPresetChoiceRow(_ preset: ManualHeaderPreset, title: String, help: String) -> some View {
        let isSelected = manualPreset == preset
        HStack(alignment: .center, spacing: 12) {
            // Radio selection
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { manualPreset = preset }
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Selected" : "Select preset")

            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noAuthCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Requests will be sent without Authorization or API key headers. Add optional custom headers in Advanced below if your server expects them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Headers block removed; use unified Advanced section in the Auth tab instead.
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    // MARK: - Basics → Status helpers

    private var authStatusText: String {
        if !server.usesOAuthAuthorization && !server.usesManualCredentials {
            return ""
        }
        if server.usesOAuthAuthorization {
            switch server.oauthStatus {
            case .authorized: return "Signed in"
            case .refreshing: return "Refreshing session"
            case .unauthorized: return "Sign-in required"
            case .error: return "Needs attention"
            }
        } else if server.usesManualCredentials {
            return "Manual access key"
        }
        return ""
    }

    private var authDetailText: String? {
        if server.usesManualCredentials {
            if let header = manualCredentialHeader {
                let name = header.header.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Authorization header configured" : "Header configured: \(name)"
            }
            return "Manual access header configured"
        }
        // Show last refresh and nearest expiry if available
        var parts: [String] = []
        if let last = server.oauthState?.lastTokenRefresh {
            parts.append("Updated \(last.mcpShortDateTime())")
        }
        if let exp = accessTokenExpiryDate() {
            parts.append("Expires \(exp.mcpShortDateTime())")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var hasStoredOAuthTokens: Bool {
        guard let state = server.oauthState else { return false }
        return !state.serializedAuthState.isEmpty
    }

    private var authActionButton: AnyView? {
        // No auth configured at all → no action
        if !server.usesOAuthAuthorization && !server.usesManualCredentials { return nil }
        guard server.usesOAuthAuthorization else { return nil }
        switch server.oauthStatus {
        case .authorized:
            return AnyView(Button("Refresh Now", action: refreshOAuthToken).buttonStyle(.bordered))
        case .refreshing:
            return AnyView(ProgressView().frame(width: 24, height: 24))
        case .unauthorized, .error:
            if hasStoredOAuthTokens {
                return AnyView(Button("Refresh Now", action: refreshOAuthToken).buttonStyle(.bordered))
            }
            return AnyView(Button("Sign In", action: runOAuthSignIn).buttonStyle(.bordered))
        }
    }

    private func accessTokenExpiryDate() -> Date? {
        guard let meta = server.oauthState?.providerMetadata else { return nil }
        if let at = meta["access_expires_at"], let date = ISO8601DateFormatter().date(from: at) {
            return date
        }
        if let secs = meta["access_expires_in_sec"], let s = Int(secs) {
            return Date().addingTimeInterval(TimeInterval(s))
        }
        return nil
    }

    private func toolCounts() -> (enabled: Int, total: Int) {
        let caps = parseCapabilities()
        let total = caps.tools.count
        if total == 0 { return (0, 0) }
        if server.includeTools.isEmpty { return (total, total) }
        let include = Set(server.includeTools)
        let enabled = caps.tools.reduce(into: 0) { count, t in if include.contains(t.name) { count += 1 } }
        return (enabled, total)
    }

    
    
    
    private func automaticPrimaryAction(for status: OAuthStatus) -> (title: String, action: (() -> Void)?, enabled: Bool) {
        switch status {
        case .unauthorized:
            let title = hasStoredOAuthTokens ? "Refresh Session" : "Sign In"
            let action: (() -> Void)? = hasStoredOAuthTokens ? { refreshOAuthToken() } : { runOAuthSignIn() }
            return (title, action, !isPerformingOAuthAction)
        case .authorized:
            return ("Try refresh", { refreshOAuthToken() }, !isPerformingOAuthAction)
        case .refreshing:
            return ("Refreshing…", nil, false)
        case .error:
            let title = hasStoredOAuthTokens ? "Refresh Session" : "Sign in again"
            let action: (() -> Void)? = hasStoredOAuthTokens ? { refreshOAuthToken() } : { runOAuthSignIn() }
            return (title, action, !isPerformingOAuthAction)
        }
    }

    private var displayOAuthStatus: OAuthStatus {
        displayStatus(for: server.oauthStatus,
                       isActive: server.oauthState?.isActive ?? false,
                       isPerforming: isPerformingOAuthAction)
    }

    private func authenticationBadge(for status: OAuthStatus) -> some View {
        OAuthStatusIndicator(status: status)
    }

    private func runOAuthSignIn() {
        guard requiresOAuth else {
            oauthActionMessage = "Add an Authorization header set to OAuth Token to enable sign-in."
            return
        }

        server.baseURL = ServerURLNormalizer.normalizeOptional(server.baseURL)
        isPerformingOAuthAction = true
        oauthActionMessage = nil
        Task { @MainActor in
            defer { isPerformingOAuthAction = false }
            guard applyManualCredentialsToServer() else { return }
            await OAuthService.shared.runAuthDiscovery(server: server, wwwAuthenticate: nil)
            guard let configuration = server.oauthConfiguration else {
                oauthActionMessage = "Discovery failed to locate OAuth metadata. Verify the server exposes /.well-known endpoints."
                server.oauthStatus = .error
                return
            }
            if useManualOAuthClient {
                configuration.clientId = manualClientId.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedSecret = manualClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.clientSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
                configuration.clientSource = .manual
            } else {
                configuration.clientSource = .dynamic
            }
            await OAuthService.shared.startAuthorizationFlow(server: server, configuration: configuration)
            manualClientId = configuration.clientId ?? manualClientId
            manualClientSecret = configuration.clientSecret ?? manualClientSecret
            try? modelContext.save()
            reloadRecentLogs()
        }
    }

    private func refreshOAuthToken() {
        guard requiresOAuth else { return }
        isPerformingOAuthAction = true
        oauthActionMessage = nil
        Task { @MainActor in
            defer { isPerformingOAuthAction = false }
            _ = await OAuthService.shared.refreshAccessToken(for: server, announce: true)
            try? modelContext.save()
        }
    }

    private func disconnectOAuth() {
        if let state = server.oauthState {
            modelContext.delete(state)
            server.oauthState = nil
        }
        if let configuration = server.oauthConfiguration {
            modelContext.delete(configuration)
            server.oauthConfiguration = nil
        }
        server.oauthDiagnostics = OAuthDiagnosticsLog()
        server.oauthStatus = .unauthorized
        oauthActionMessage = "Disconnected. Run Sign In to establish a new session."
        try? modelContext.save()
    }

    private func parseCapabilities() -> MCPCapabilities {
        guard let latest = server.capabilityCaches.sorted(by: { $0.generatedAt > $1.generatedAt }).first,
              let decoded = try? JSONDecoder().decode(MCPCapabilities.self, from: latest.payload) else {
            return MCPCapabilities(serverName: nil, serverDescription: nil, tools: [])
        }
        return decoded
    }

    private func applyManualCredentialsToServer() -> Bool {
        if server.oauthConfiguration == nil {
            server.oauthConfiguration = OAuthConfiguration(server: server)
        }
        guard let configuration = server.oauthConfiguration else { return true }
        if useManualOAuthClient {
            let trimmedId = manualClientId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedId.isEmpty else {
                oauthActionMessage = "Client ID is required when using manual credentials."
                server.oauthStatus = .error
                return false
            }
            configuration.clientId = trimmedId
            let trimmedSecret = manualClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.clientSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
        } else if configuration.clientId?.isEmpty ?? true {
            configuration.clientId = nil
            configuration.clientSecret = nil
        }
        return true
    }

    private func makeTestOAuthConfigurationCopy(from configuration: OAuthConfiguration?, server: Server) -> OAuthConfiguration? {
        guard let configuration else { return nil }
        let clientId = useManualOAuthClient ? manualClientId.trimmingCharacters(in: .whitespacesAndNewlines) : configuration.clientId
        let clientSecret = useManualOAuthClient ? manualClientSecret.trimmingCharacters(in: .whitespacesAndNewlines) : configuration.clientSecret
        return OAuthConfiguration(server: server,
                                  authorizationEndpoint: configuration.authorizationEndpoint,
                                  tokenEndpoint: configuration.tokenEndpoint,
                                  registrationEndpoint: configuration.registrationEndpoint,
                                  jwksEndpoint: configuration.jwksEndpoint,
                                  scopes: configuration.scopes,
                                  clientId: clientId,
                                  clientSecret: clientSecret,
                                  usePKCE: configuration.usePKCE,
                                  resourceURI: configuration.resourceURI,
                                  discoveredAt: configuration.discoveredAt,
                                  metadataVersion: configuration.metadataVersion)
    }
}

private func displayStatus(for status: OAuthStatus, isActive: Bool, isPerforming: Bool) -> OAuthStatus {
    if status == .refreshing && !isPerforming {
        return isActive ? .authorized : .unauthorized
    }
    return status
}

// (Former custom CollapsibleSection removed; using segmented tabs instead.)
