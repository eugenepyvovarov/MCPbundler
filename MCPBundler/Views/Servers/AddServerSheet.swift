//
//  AddServerSheet.swift
//  MCP Bundler
//
//  Modal sheet used to register a new server with a project.
//

import SwiftUI
import SwiftData
import MCP

struct ServerConnectionTestGuidance {
    enum SignInMode {
        case none
        case automaticOAuth
        case manualHeader
    }

    struct PreflightOutcome: Equatable {
        var headers: [HeaderBinding]
        var oauthActionMessage: String
        var healthStatus: HealthStatus
    }

    struct ErrorOutcome: Equatable {
        var headers: [HeaderBinding]
        var oauthActionMessage: String
    }

    static func preflight(kind: ServerKind,
                          signInMode: SignInMode,
                          headers: [HeaderBinding],
                          useManualOAuthClient: Bool,
                          manualClientId: String) -> PreflightOutcome? {
        guard kind == .remote_http_sse else { return nil }
        guard signInMode == .automaticOAuth else { return nil }

        var updatedHeaders = headers
        if !updatedHeaders.contains(where: { $0.valueSource == .oauthAccessToken }) {
            ensureOAuthHeaderPresent(in: &updatedHeaders)
            return PreflightOutcome(headers: updatedHeaders,
                                    oauthActionMessage: "Authentication required. Sign in to continue.",
                                    healthStatus: .unhealthy)
        }

        if useManualOAuthClient && manualClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PreflightOutcome(headers: updatedHeaders,
                                    oauthActionMessage: "Manual OAuth client credentials required. Enter client ID/secret before continuing.",
                                    healthStatus: .unhealthy)
        }

        return nil
    }

    static func guidanceAfterError(kind: ServerKind,
                                   signInMode: SignInMode,
                                   headers: [HeaderBinding],
                                   error: Error) -> ErrorOutcome? {
        guard kind == .remote_http_sse else { return nil }

        var updatedHeaders = headers
        if OAuthRetryPolicy.isAuthenticationError(error) {
            if signInMode == .automaticOAuth {
                ensureOAuthHeaderPresent(in: &updatedHeaders)
            }
            return ErrorOutcome(headers: updatedHeaders,
                                oauthActionMessage: "Authentication required. Sign in to continue.")
        }

        if isEndpointMissingError(error) {
            if signInMode == .automaticOAuth {
                ensureOAuthHeaderPresent(in: &updatedHeaders)
            }
            return ErrorOutcome(headers: updatedHeaders,
                                oauthActionMessage: "Endpoint not found. Sign in first so Jura can expose its capability routes.")
        }

        return nil
    }

    private static func ensureOAuthHeaderPresent(in headers: inout [HeaderBinding]) {
        guard !headers.contains(where: { $0.valueSource == .oauthAccessToken }) else { return }
        headers.append(
            HeaderBinding(server: nil,
                          header: "Authorization",
                          valueSource: .oauthAccessToken,
                          plainValue: nil,
                          keychainRef: nil)
        )
    }

    private static func isEndpointMissingError(_ error: Error) -> Bool {
        guard case let MCPError.transportError(underlying) = error,
              let urlError = underlying as? URLError,
              urlError.code == .fileDoesNotExist else {
            return false
        }
        return true
    }
}

struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.stdiosessionController) private var stdiosessionController

    @State private var kind: ServerKind = .local_stdio
    @State private var alias: String = ""

    // Local STDIO
    @State private var execPath: String = ""
    @State private var argsText: String = ""
    @State private var envOverridesState: [EnvVar] = []
    @State private var setupLogEntries: [SetupLogEntry] = []
    @State private var setupSessionID: UUID = UUID()
    @State private var setupLogAlias: String = ""

    // Remote HTTP/SSE
    @State private var baseURL: String = ""
    @State private var headersState: [HeaderBinding] = []

    @State private var remoteEnvOverridesState: [EnvVar] = []
    @State private var signInMode: SignInMode = .none
    @State private var manualPreset: ManualHeaderPreset = .bearer
    @State private var manualCustomHeaderName: String = "Authorization"
    @State private var manualTokenValue: String = ""
    @State private var isSyncingManualState: Bool = false
    @State private var showManualValue: Bool = false

    @State private var selectedFolderID: PersistentIdentifier?

    @State private var errorText: String?
    @State private var persistenceError: String?
    @State private var isTesting = false
    @State private var testResult: HealthStatus = .unknown
    @State private var previewCapabilities: MCPCapabilities?
    @State private var selectedTools: [String] = []
    @State private var showingToolDetail: MCPTool?
    @State private var oauthDraftServer: Server?
    @State private var isPerformingOAuthAction: Bool = false
    @State private var oauthActionMessage: String?
    @State private var useManualOAuthClient: Bool = false
    @State private var manualClientId: String = ""
    @State private var manualClientSecret: String = ""
    @State private var showOAuthDiagnostics = false
    @State private var remoteAdvancedExpanded: Bool = false

#if DEBUG
    var testingModelContext: ModelContext?
#endif

    private let columnLabelWidth: CGFloat = 70
    private let sheetWidth: CGFloat = 640
    private let logScrollAnchorID = "setupLogBottom"

    var project: Project
    private var sortedFolders: [ProviderFolder] {
        project.folders.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
    private var selectedFolder: ProviderFolder? {
        guard let id = selectedFolderID else { return nil }
        return sortedFolders.first { $0.stableID == id }
    }

    init(project: Project) {
        self.project = project
    }

#if DEBUG
    init(project: Project, initialKind: ServerKind, initialAlias: String = "", initialBaseURL: String = "") {
        self.project = project
        _kind = State(initialValue: initialKind)
        _alias = State(initialValue: initialAlias)
        _baseURL = State(initialValue: initialBaseURL)
        if initialKind == .remote_http_sse {
            _signInMode = State(initialValue: .automatic)
            _headersState = State(initialValue: [
                HeaderBinding(server: nil,
                              header: "Authorization",
                              valueSource: .oauthAccessToken,
                              plainValue: nil,
                              keychainRef: nil)
            ])
        } else {
            _signInMode = State(initialValue: .none)
        }
    }
#endif

    private var activeModelContext: ModelContext {
#if DEBUG
        testingModelContext ?? modelContext
#else
        modelContext
#endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add Server")
                        .font(.title2)

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Kind")
                            .frame(width: columnLabelWidth, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $kind) {
                            Text("Local STDIO").tag(ServerKind.local_stdio)
                            Text("Remote HTTP/SSE").tag(ServerKind.remote_http_sse)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Folder")
                            .frame(width: columnLabelWidth, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $selectedFolderID) {
                            Text("Unfoldered").tag(PersistentIdentifier?.none)
                            ForEach(sortedFolders, id: \.stableID) { folder in
                                Text(folder.name).tag(folder.stableID as PersistentIdentifier?)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if kind == .local_stdio {
                        GroupBox("Basics") {
                            localBasicsSection
                        }

                        localTestActionRow

                        setupLogSection

                        GroupBox("Tools Preview") {
                            toolsPreview
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            GroupBox("Basics") { remoteBasicsSection }
                                .frame(maxWidth: .infinity)
                            GroupBox("Sign-In Method") { remoteSignInSection }
                                .frame(maxWidth: .infinity)
                            CollapsibleCard(
                                isExpanded: $remoteAdvancedExpanded,
                                iconName: "slider.horizontal.3",
                                title: "Advanced Options",
                                subtitle: "OAuth diagnostics, headers, environment overrides."
                            ) {
                                VStack(alignment: .leading, spacing: 16) {
                                    Toggle("Enable OAuth debug logging", isOn: Binding(
                                        get: { oauthDraftServer?.isOAuthDebugLoggingEnabled ?? false },
                                        set: { newValue in
                                            if oauthDraftServer == nil {
                                                _ = synchronizeDraftServer()
                                            }
                                            oauthDraftServer?.isOAuthDebugLoggingEnabled = newValue
                                        }
                                    ))
                                    .font(.footnote)
                                    .help("Record verbose OAuth activity in project logs to troubleshoot discovery, sign-in, refresh, and capability fetch steps.")

                                    remoteHeadersSection
                                    Divider()
                                    remoteEnvironmentSection
                                }
                            }
                            .frame(maxWidth: .infinity)

                            localTestActionRow

                            setupLogSection

                            GroupBox("Tools Preview") {
                                toolsPreview
                            }
                        }
                        .onAppear {
                            synchronizeDraftServer()
                            applySignInModeEffects()
                        }
                    }

                    if let persistenceError {
                        Text(persistenceError)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: sheetWidth, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)

            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    clearSetupLogs(deletePersisted: true)
                    discardOAuthDraftServer()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: sheetWidth, alignment: .trailing)
            .padding([.horizontal, .bottom, .top])
        }
        .onExitCommand {
            clearSetupLogs(deletePersisted: true)
            discardOAuthDraftServer()
            dismiss()
        }
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
        .sheet(isPresented: $showOAuthDiagnostics) {
            if let server = oauthDraftServer {
                NavigationStack {
                    OAuthDiagnosticsView(server: server)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showOAuthDiagnostics = false }
                            }
                        }
                }
            } else {
                VStack(spacing: 12) {
                    Text("Diagnostics unavailable.")
                    Text("Create a draft remote server first, then try again.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .onChange(of: kind) { _, newValue in
            clearSetupLogs(deletePersisted: true)
            invalidatePreview()
            if newValue == .local_stdio {
                headersState.removeAll()
                remoteEnvOverridesState.removeAll()
                signInMode = .none
                manualPreset = .bearer
                manualCustomHeaderName = "Authorization"
                manualTokenValue = ""
                discardOAuthDraftServer()
            } else {
                if signInMode == .none {
                    signInMode = .automatic
                }
                applySignInModeEffects()
                _ = synchronizeDraftServer()
            }
            remoteAdvancedExpanded = false
        }
        .onChange(of: alias) { _, _ in
            invalidatePreview()
            if kind == .remote_http_sse { synchronizeDraftServer() }
        }
        .onChange(of: execPath) { _, _ in invalidatePreview() }
        .onChange(of: argsText) { _, _ in invalidatePreview() }
        .onChange(of: baseURL) { _, _ in
            invalidatePreview()
            if kind == .remote_http_sse { synchronizeDraftServer() }
        }
        .onChange(of: signInMode) { _, _ in
            applySignInModeEffects()
            if kind == .remote_http_sse { synchronizeDraftServer() }
        }
        .onChange(of: manualPreset) { _, _ in
            showManualValue = false
            updateManualHeaderFromState()
            if kind == .remote_http_sse { synchronizeDraftServer() }
        }
        .onChange(of: manualTokenValue) { _, _ in
            updateManualHeaderFromState()
            if kind == .remote_http_sse { synchronizeDraftServer() }
        }
        .onChange(of: manualCustomHeaderName) { _, _ in
            if manualPreset == .custom {
                updateManualHeaderFromState()
                if kind == .remote_http_sse { synchronizeDraftServer() }
            }
        }
    }


    private enum SignInMode: String, CaseIterable, Identifiable {
        case none
        case automatic
        case manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "No Authentication"
            case .automatic: return "Automatic (OAuth)"
            case .manual: return "Manual Access Key"
            }
        }
    }

    private enum ManualHeaderPreset: String, CaseIterable, Identifiable {
        case bearer
        case basic
        case apiKey
        case custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bearer: return "Bearer"
            case .basic: return "Basic"
            case .apiKey: return "API Key"
            case .custom: return "Custom"
            }
        }
    }

    private var normalizedBaseURL: String {
        ServerURLNormalizer.normalize(baseURL)
    }

    private var localConfiguration: some View {
        LocalStdioConfigurationForm(
            layout: .labeled(width: columnLabelWidth),
            execLabel: "Executable",
            argsLabel: "Arguments",
            envLabel: "Env Vars",
            execPlaceholder: "Enter executable path",
            argsPlaceholder: "Space-separated (e.g., --flag value)",
            addEnvButtonLabel: "Add Variable",
            showEnvValues: true,
            execPath: $execPath,
            argumentsText: $argsText,
            envVars: envOverridesState,
            onAddEnvVar: addEnvOverride,
            onDeleteEnvVar: { env in
                if let idx = envOverridesState.firstIndex(where: { $0 === env }) {
                    envOverridesState.remove(at: idx)
                    envOverridesState.normalizeEnvPositions()
                }
            }
        )
    }

    private var localBasicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Alias")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("Alias (e.g., stripe)", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            if let aliasValidationMessage {
                HStack(alignment: .top, spacing: 12) {
                    Text("")
                        .frame(width: columnLabelWidth, alignment: .trailing)
                    Text(aliasValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            localConfiguration
        }
        .padding(12)
    }

    private var localTestActionRow: some View {
        HStack {
            Spacer()
            Button(action: testConnection) {
                HStack(spacing: 12) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                    }
                    Text(isTesting ? "Testing..." : "Test Server")
                        .font(.headline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSave || isTesting)
            Spacer()
        }
    }

    private var setupLogSection: some View {
        GroupBox {
            setupLogContent
        } label: {
            HStack {
                Text("Setup Log")
                Spacer()
                if !isTesting && testResult != .unknown {
                    HealthBadge(status: testResult)
                }
            }
        }
    }

    @ViewBuilder
    private var setupLogContent: some View {
        if setupLogEntries.isEmpty {
            ZStack {
                Text("Run Test Server to capture launch output.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(setupLogEntries) { entry in
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
                            .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(logScrollAnchorID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160, maxHeight: 240)
                .onChange(of: setupLogEntries.count) { _, _ in
                    withAnimation {
                        scrollProxy.scrollTo(logScrollAnchorID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var remoteBasicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Alias")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("alias", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            if let aliasValidationMessage {
                HStack(alignment: .top, spacing: 12) {
                    Text("")
                        .frame(width: columnLabelWidth, alignment: .trailing)
                    Text(aliasValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Base URL")
                    .frame(width: columnLabelWidth, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("https://api.example.com/mcp", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Use the MCP endpoint your provider documents (paths like `/mcp` are preserved).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var remoteSignInSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Sign-In Mode", selection: $signInMode) {
                ForEach([SignInMode.none, .automatic, .manual]) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            switch signInMode {
            case .automatic:
                remoteAuthenticationSection
            case .manual:
                manualAccessKeySection
            case .none:
                VStack(alignment: .leading, spacing: 8) {
                    Text("No authentication headers will be added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var additionalHeaders: [HeaderBinding] {
        headersState.filter { $0.keychainRef != HeaderBinding.manualCredentialMarker && $0.valueSource != .oauthAccessToken }
    }

    private var remoteHeadersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Additional Headers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { addHeader() } label: { Label("Add Header", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            if additionalHeaders.isEmpty {
                Text("No additional headers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HeaderEditor(headers: additionalHeaders, onDelete: { header in
                    guard header.keychainRef != HeaderBinding.manualCredentialMarker else { return }
                    header.modelContext?.delete(header)
                    if let idx = headersState.firstIndex(where: { $0 === header }) {
                        headersState.remove(at: idx)
                    }
                }, allowsOAuthSource: false)
            }
        }
    }

    private var remoteEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment Overrides")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { addRemoteEnvOverride() } label: { Label("Add Variable", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            if remoteEnvOverridesState.isEmpty {
                Text("No environment overrides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                EnvEditor(envVars: remoteEnvOverridesState, onDelete: { env in
                    if let idx = remoteEnvOverridesState.firstIndex(where: { $0 === env }) {
                        remoteEnvOverridesState.remove(at: idx)
                        remoteEnvOverridesState.normalizeEnvPositions()
                    }
                }, showValues: false)
            }
        }
    }

    private var manualAccessKeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provide headers or access keys shared by your provider. Values remain local to this Mac and are masked by default.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Primary Header")
                    .font(.subheadline.weight(.semibold))

                manualPresetChoiceRow(.bearer,
                                      title: "Authorization · Bearer",
                                      help: "Adds Bearer <token> to Authorization")
                manualPresetChoiceRow(.basic,
                                      title: "Authorization · Basic",
                                      help: "Adds Basic <token> to Authorization")
                manualPresetChoiceRow(.apiKey,
                                      title: "X-API-Key",
                                      help: "Sends X-API-Key: <value>")
                manualPresetChoiceRow(.custom,
                                      title: "Custom",
                                      help: "Choose any header name and value")

                HStack(spacing: 8) {
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("VALUE")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if showManualValue {
                                TextField("Value", text: $manualTokenValue)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Value", text: .constant(String(repeating: "*", count: max(manualTokenValue.count, 1))))
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

                Text(manualPresetHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .onAppear {
            ensureManualCredentialHeader()
            syncManualStateFromHeader()
            showManualValue = false
        }
    }

    private var manualPresetHelpText: String {
        switch manualPreset {
        case .bearer:
            return "We’ll send Authorization: Bearer <token> with the value you enter."
        case .basic:
            return "We’ll send Authorization: Basic <token> with the value you enter."
        case .apiKey:
            return "We’ll send X-API-Key: <value>."
        case .custom:
            return "Choose any header name and value required by your provider."
        }
    }

    @ViewBuilder
    private func manualPresetChoiceRow(_ preset: ManualHeaderPreset,
                                       title: String,
                                       help: String) -> some View {
        let isSelected = manualPreset == preset
        HStack(alignment: .center, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    manualPreset = preset
                }
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

    private var toolsPreview: some View {
        let info = previewCapabilities
        return VStack(alignment: .leading, spacing: 12) {
            if let info = info, !info.tools.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(info.tools.enumerated()), id: \.element.name) { index, tool in
                        HStack {
                            Text(tool.name)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle("", isOn: Binding(
                                get: {
                                    selectedTools.contains(tool.name)
                                },
                                set: { newValue in
                                    if newValue {
                                        if !selectedTools.contains(tool.name) {
                                            selectedTools.append(tool.name)
                                        }
                                    } else {
                                        selectedTools.removeAll { $0 == tool.name }
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .frame(width: 80)

                            Button("Preview") {
                                showingToolDetail = tool
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(width: 80)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)

                        if index < info.tools.count - 1 {
                            Divider()
                        }
                    }
                }
            } else if let info = info {
                Text("No tools available.").foregroundStyle(.secondary)
            } else {
                ZStack {
                    Text("Run Test Server to preview tools.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }

            if let info = info, let resources = info.resources, !resources.isEmpty {
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

            if let info = info, let prompts = info.prompts, !prompts.isEmpty {
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
    }

    private var trimmedAlias: String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var aliasValidationMessage: String? {
        let value = trimmedAlias
        guard !value.isEmpty else { return "Alias is required." }
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return "Alias can include letters (A-Z or a-z), numbers, underscores, and hyphens."
        }
        guard !project.servers.contains(where: { server in
            guard server.alias.caseInsensitiveCompare(value) == .orderedSame else { return false }
            if let draft = oauthDraftServer, server.persistentModelID == draft.persistentModelID {
                return false
            }
            return true
        }) else {
            return "Alias already exists in this project."
        }
        return nil
    }

    private var canSave: Bool {
        guard aliasValidationMessage == nil else { return false }

        switch kind {
        case .local_stdio:
            return !execPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .remote_http_sse:
            return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canTestConnection: Bool {
        switch kind {
        case .local_stdio:
            return !execPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .remote_http_sse:
            return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var requiresOAuth: Bool {
        headersState.contains { $0.valueSource == .oauthAccessToken }
    }

    private var currentOAuthStatus: OAuthStatus {
        guard let draft = oauthDraftServer else { return .unauthorized }
        return displayStatus(for: draft.oauthStatus,
                              isActive: draft.oauthState?.isActive ?? false,
                              isPerforming: isPerformingOAuthAction)
    }

    private func invalidatePreview() {
        previewCapabilities = nil
        selectedTools = []
        errorText = nil
        testResult = .unknown
    }

    private func ensureOAuthDraftServer() -> Server {
        if let existing = oauthDraftServer { return existing }
        let draft = Server(project: project, alias: "", kind: .remote_http_sse)
        activeModelContext.insert(draft)
        oauthDraftServer = draft
        return draft
    }

    private func discardOAuthDraftServer() {
        if let draft = oauthDraftServer {
            for header in draft.headers {
                activeModelContext.delete(header)
            }
            activeModelContext.delete(draft)
            oauthDraftServer = nil
            headersState.removeAll()
        }
        manualClientId = ""
        manualClientSecret = ""
        useManualOAuthClient = false
    }

    @discardableResult
    private func synchronizeDraftServer() -> Server? {
        guard kind == .remote_http_sse else { return nil }
        let draft = ensureOAuthDraftServer()
        draft.alias = trimmedAlias
        draft.baseURL = normalizedBaseURL

        draft.headers.removeAll()
        for header in headersState {
            header.server = draft
            if header.persistentModelID == nil {
                activeModelContext.insert(header)
            }
            draft.headers.append(header)
        }

        draft.envOverrides.removeAll()
        let orderedOverrides = remoteEnvOverridesState.sorted { $0.position < $1.position }
        for envVar in orderedOverrides {
            let copy = EnvVar(server: draft,
                              key: envVar.key,
                              valueSource: envVar.valueSource,
                              plainValue: envVar.plainValue,
                              keychainRef: envVar.keychainRef,
                              position: envVar.position)
            draft.envOverrides.append(copy)
        }

        if signInMode == .automatic {
            if draft.oauthConfiguration == nil {
                draft.oauthConfiguration = OAuthConfiguration(server: draft)
            }
            if !useManualOAuthClient,
               let existingId = draft.oauthConfiguration?.clientId,
               !existingId.isEmpty {
                manualClientId = existingId
                manualClientSecret = draft.oauthConfiguration?.clientSecret ?? ""
                if draft.oauthConfiguration?.registrationEndpoint == nil {
                    useManualOAuthClient = true
                }
            }
        } else {
            draft.oauthConfiguration?.clientId = nil
            draft.oauthConfiguration?.clientSecret = nil
        }
        return draft
    }

    private func ensureOAuthHeaderPresent() {
        guard !headersState.contains(where: { $0.valueSource == .oauthAccessToken }) else { return }
        let draft = ensureOAuthDraftServer()
        let header = HeaderBinding(server: draft,
                                   header: "Authorization",
                                   valueSource: .oauthAccessToken,
                                   plainValue: nil,
                                   keychainRef: nil)
        headersState.append(header)
    }

    private var manualCredentialHeader: HeaderBinding? {
        headersState.first { $0.keychainRef == HeaderBinding.manualCredentialMarker }
    }

    @discardableResult
    private func ensureManualCredentialHeader() -> HeaderBinding {
        if let header = manualCredentialHeader {
            header.keychainRef = HeaderBinding.manualCredentialMarker
            header.valueSource = .plain
            return header
        }
        let header = HeaderBinding(server: nil, header: manualHeaderName(for: manualPreset), valueSource: .plain, plainValue: "")
        header.keychainRef = HeaderBinding.manualCredentialMarker
        headersState.insert(header, at: 0)
        return header
    }

    private func manualHeaderName(for preset: ManualHeaderPreset) -> String {
        switch preset {
        case .bearer, .basic:
            return "Authorization"
        case .apiKey:
            return "X-API-Key"
        case .custom:
            let trimmed = manualCustomHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "X-Custom-Header" : trimmed
        }
    }

    private func removeManualCredentialHeader() {
        let manuals = headersState.filter { $0.keychainRef == HeaderBinding.manualCredentialMarker }
        for header in manuals {
            header.modelContext?.delete(header)
        }
        headersState.removeAll { $0.keychainRef == HeaderBinding.manualCredentialMarker }
    }

    private func removeOAuthHeader() {
        let oauthHeaders = headersState.filter { $0.valueSource == .oauthAccessToken }
        for header in oauthHeaders {
            header.modelContext?.delete(header)
        }
        headersState.removeAll { $0.valueSource == .oauthAccessToken }
    }

    private func syncManualStateFromHeader(_ header: HeaderBinding? = nil) {
        guard kind == .remote_http_sse else { return }
        let target = header ?? manualCredentialHeader
        isSyncingManualState = true
        manualPreset = resolveManualPreset(for: target)
        manualCustomHeaderName = manualHeaderName(for: manualPreset)
        if manualPreset == .custom, let header = target {
            manualCustomHeaderName = header.header
        }
        manualTokenValue = target.map { manualToken(for: $0, preset: manualPreset) } ?? ""
        isSyncingManualState = false
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

    private func resolveManualPreset(for header: HeaderBinding?) -> ManualHeaderPreset {
        guard let header else { return .bearer }
        let name = header.header.lowercased()
        if header.keychainRef == HeaderBinding.manualCredentialMarker {
            if name == "authorization", let value = header.plainValue?.lowercased() {
                if value.hasPrefix("bearer ") { return .bearer }
                if value.hasPrefix("basic ") { return .basic }
            }
            if name == "x-api-key" { return .apiKey }
            return .custom
        }
        return .custom
    }

    private func updateManualHeaderFromState() {
        guard kind == .remote_http_sse, signInMode == .manual, !isSyncingManualState else { return }
        let header = ensureManualCredentialHeader()
        let trimmedToken = manualTokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch manualPreset {
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
            manualCustomHeaderName = header.header
            header.plainValue = trimmedToken
        }
        header.valueSource = .plain
        header.keychainRef = HeaderBinding.manualCredentialMarker
    }

    private func applySignInModeEffects() {
        guard kind == .remote_http_sse else { return }
        switch signInMode {
        case .automatic:
            ensureOAuthHeaderPresent()
            removeManualCredentialHeader()
            showManualValue = false
        case .manual:
            removeOAuthHeader()
            showManualValue = false
            let header = ensureManualCredentialHeader()
            syncManualStateFromHeader(header)
            updateManualHeaderFromState()
        case .none:
            removeOAuthHeader()
            removeManualCredentialHeader()
            manualTokenValue = ""
            showManualValue = false
        }
    }

    private func addRemoteEnvOverride() {
        let nextPosition = remoteEnvOverridesState.nextEnvPosition()
        remoteEnvOverridesState.append(
            EnvVar(server: nil,
                   key: "",
                   valueSource: .plain,
                   plainValue: "",
                   position: nextPosition)
        )
    }

    private func testConnection() {
        Task { @MainActor in
            await testConnectionAsync()
        }
    }

    @MainActor
    private func testConnectionAsync() async {
        guard canTestConnection else { return }
        let guidanceSignInMode: ServerConnectionTestGuidance.SignInMode
        switch signInMode {
        case .none:
            guidanceSignInMode = .none
        case .automatic:
            guidanceSignInMode = .automaticOAuth
        case .manual:
            guidanceSignInMode = .manualHeader
        }
        let sanitizedAlias = trimmedAlias
        prepareLogSession(for: sanitizedAlias)

        appendSetupLog(level: .info, message: "Starting test for \(sanitizedAlias.isEmpty ? "new server" : "\"\(sanitizedAlias)\"") (\(kind == .local_stdio ? "Local STDIO" : "Remote HTTP/SSE")).")

        if let outcome = ServerConnectionTestGuidance.preflight(kind: kind,
                                                                signInMode: guidanceSignInMode,
                                                                headers: headersState,
                                                                useManualOAuthClient: useManualOAuthClient,
                                                                manualClientId: manualClientId) {
            let wasMissingOAuthHeader = !headersState.contains(where: { $0.valueSource == .oauthAccessToken })
            headersState = outcome.headers
            if wasMissingOAuthHeader {
                appendSetupLog(level: .error,
                               message: "OAuth header missing. Added Authorization header placeholder; sign in before testing again.")
            } else {
                appendSetupLog(level: .error, message: "Manual OAuth credentials required before testing.")
            }
            oauthActionMessage = outcome.oauthActionMessage
            testResult = outcome.healthStatus
            return
        }

        isTesting = true
        testResult = .unknown
        previewCapabilities = nil
        errorText = nil

        if kind == .local_stdio {
            appendSetupLog(level: .debug, message: "Executable path: \(execPath)")
            if !argsText.trimmingCharacters(in: .whitespaces).isEmpty {
                appendSetupLog(level: .debug, message: "Arguments: \(argsText)")
            }
            if !envOverridesState.isEmpty {
                let keys = envOverridesState.map { envVar -> String in
                    let key = envVar.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    return key.isEmpty ? "(blank)" : key
                }
                appendSetupLog(level: .debug, message: "Environment overrides: \(keys.joined(separator: ", "))")
            }
        } else {
            appendSetupLog(level: .debug, message: "Base URL: \(normalizedBaseURL)")
            appendSetupLog(level: .debug, message: "Headers configured: \(headersState.count)")
        }

        defer { isTesting = false }

        do {
            let tmp: Server
            switch kind {
            case .local_stdio:
                tmp = Server(project: project, alias: sanitizedAlias, kind: kind)
                tmp.execPath = execPath
                tmp.args = argsText.split(separator: " ").map(String.init)
                let orderedOverrides = envOverridesState.sorted { $0.position < $1.position }
                tmp.envOverrides = orderedOverrides.map { envVar in
                    EnvVar(server: tmp,
                           key: envVar.key,
                           valueSource: envVar.valueSource,
                           plainValue: envVar.plainValue,
                           keychainRef: envVar.keychainRef,
                           position: envVar.position)
                }
            case .remote_http_sse:
                applySignInModeEffects()
                guard let draft = synchronizeDraftServer() else {
                    throw MCPError.internalError("Missing draft server")
                }
                draft.alias = sanitizedAlias
                draft.baseURL = normalizedBaseURL

                switch signInMode {
                case .automatic:
                    if !headersState.contains(where: { $0.valueSource == .oauthAccessToken }) {
                        ensureOAuthHeaderPresent()
                        synchronizeDraftServer()
                        oauthActionMessage = "Authentication required. Sign in to continue."
                        appendSetupLog(level: .error, message: "OAuth header still missing after synchronization.")
                        testResult = .unhealthy
                        return
                    }
                    guard applyManualCredentials(to: draft) else {
                        oauthActionMessage = "Manual OAuth client credentials required. Enter client ID/secret before continuing."
                        appendSetupLog(level: .error, message: "Manual OAuth credentials required before testing.")
                        testResult = .unhealthy
                        return
                    }
                case .manual:
                    updateManualHeaderFromState()
                    oauthActionMessage = nil
                case .none:
                    oauthActionMessage = nil
                }

                tmp = draft
            }

            let provider = CapabilitiesService.provider(for: tmp)
            appendSetupLog(level: .debug, message: "Fetching capabilities using \(String(describing: type(of: provider)))")
            let capabilities = try await provider.fetchCapabilities(for: tmp)
            previewCapabilities = capabilities
            selectedTools = capabilities.tools.map { $0.name }
            appendSetupLog(level: .info,
                           message: "Test succeeded. Tools: \(capabilities.tools.count), resources: \(capabilities.resources?.count ?? 0), prompts: \(capabilities.prompts?.count ?? 0).")
            testResult = .healthy
        } catch {
            previewCapabilities = nil
            let description = describeError(error)
            appendSetupLog(level: .error, message: description)
            errorText = description
            testResult = .unhealthy
            if kind == .remote_http_sse {
                if let outcome = ServerConnectionTestGuidance.guidanceAfterError(kind: kind,
                                                                                signInMode: guidanceSignInMode,
                                                                                headers: headersState,
                                                                                error: error) {
                    headersState = outcome.headers
                    synchronizeDraftServer()
                    oauthActionMessage = outcome.oauthActionMessage
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let sanitizedAlias = trimmedAlias
        let server: Server
        switch kind {
        case .local_stdio:
            server = Server(project: project, alias: sanitizedAlias, kind: .local_stdio)
            activeModelContext.insert(server)
            server.execPath = execPath
            server.args = argsText.split(separator: " ").map(String.init)
            let orderedOverrides = envOverridesState.sorted { $0.position < $1.position }
            for envVar in orderedOverrides {
                let newEnvVar = EnvVar(
                    server: server,
                    key: envVar.key,
                    valueSource: envVar.valueSource,
                    plainValue: envVar.plainValue,
                    keychainRef: envVar.keychainRef,
                    position: envVar.position
                )
                server.envOverrides.append(newEnvVar)
            }
        case .remote_http_sse:
            let draft = synchronizeDraftServer() ?? Server(project: project, alias: sanitizedAlias, kind: .remote_http_sse)
            draft.alias = sanitizedAlias
            draft.baseURL = normalizedBaseURL
            draft.project = project
            draft.headers.removeAll()
            for header in headersState {
                header.server = draft
                if header.persistentModelID == nil {
                    activeModelContext.insert(header)
                }
                draft.headers.append(header)
            }
            draft.envOverrides.removeAll()
            let orderedRemoteOverrides = remoteEnvOverridesState.sorted { $0.position < $1.position }
            for envVar in orderedRemoteOverrides {
                let newEnvVar = EnvVar(
                    server: draft,
                    key: envVar.key,
                    valueSource: envVar.valueSource,
                    plainValue: envVar.plainValue,
                    keychainRef: envVar.keychainRef,
                    position: envVar.position
                )
                draft.envOverrides.append(newEnvVar)
            }
            if signInMode == .automatic {
                _ = applyManualCredentials(to: draft)
            } else {
                draft.oauthConfiguration?.clientId = nil
                draft.oauthConfiguration?.clientSecret = nil
            }
            if let draftToggle = oauthDraftServer?.isOAuthDebugLoggingEnabled {
                draft.isOAuthDebugLoggingEnabled = draftToggle
            }
            if draft.persistentModelID == nil {
                activeModelContext.insert(draft)
            }
            server = draft
            oauthDraftServer = nil
        }

        server.folder = selectedFolder
        if let folder = selectedFolder, folder.isEnabled == false {
            server.isEnabled = false
        }
        promoteSetupLogs(to: sanitizedAlias)

        if !project.servers.contains(where: { $0 === server }) {
            project.servers.append(server)
        }

        if let caps = previewCapabilities, let data = try? JSONEncoder().encode(caps) {
            server.replaceCapabilityCache(payload: data, in: activeModelContext)
            server.lastHealth = .healthy
            server.lastCheckedAt = Date()
            // Set the selected tools on the server
            server.includeTools = selectedTools.isEmpty ? caps.tools.map { $0.name } : selectedTools
        }

        do {
            try activeModelContext.save()
            persistenceError = nil
            let target = project
            let context = activeModelContext
            Task { @MainActor in
                try? await ProjectSnapshotCache.rebuildSnapshot(for: target)
                BundlerEventService.emit(in: context,
                                         project: target,
                                         servers: [server],
                                         type: .serverAdded)
                let projectID = target.persistentModelID
                let serverID = server.persistentModelID
                await stdiosessionController?.reload(projectID: projectID,
                                                     serverIDs: Set([serverID]))
                if context.hasChanges {
                    try? context.save()
                }
            }
            dismiss()
        } catch {
            persistenceError = "Failed to save server: \(error.localizedDescription)"
        }
    }

    private func addEnvOverride() {
        let nextPosition = envOverridesState.nextEnvPosition()
        envOverridesState.append(
            EnvVar(server: nil,
                   key: "",
                   valueSource: .plain,
                   plainValue: "",
                   position: nextPosition)
        )
    }

    private func addHeader() {
        if kind == .local_stdio {
            headersState.append(HeaderBinding(server: nil, header: "", valueSource: .plain, plainValue: ""))
        } else {
            let draft = ensureOAuthDraftServer()
            headersState.append(HeaderBinding(server: draft, header: "", valueSource: .plain, plainValue: ""))
        }
    }

    private func applyManualCredentials(to server: Server) -> Bool {
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
            return true
        } else if configuration.clientId?.isEmpty ?? true {
            configuration.clientId = nil
            configuration.clientSecret = nil
        }
        return true
    }

    private var remoteAuthenticationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                authenticationBadge(for: currentOAuthStatus)
                if let lastRefresh = oauthDraftServer?.oauthState?.lastTokenRefresh {
                    Text("Last refreshed \(lastRefresh.mcpShortDateTime())")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
            }

            Text("Authorize this remote server to receive OAuth tokens automatically.")
                .font(.footnote)
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

            Button("Sign In", action: runOAuthSignInAction)
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingOAuthAction)

            if let oauthActionMessage {
                Text(oauthActionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPerformingOAuthAction {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
    }
}

private extension AddServerSheet {
    @ViewBuilder
    private func authenticationBadge(for status: OAuthStatus) -> some View {
        switch signInMode {
        case .manual:
            Label("Manual access key", systemImage: "key.fill")
                .foregroundStyle(Color.accentColor)
        case .none:
            Label("No authentication", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case .automatic:
            let (label, color): (String, Color) = {
                switch status {
                case .unauthorized: return ("Sign-in required", .orange)
                case .authorized: return ("Signed in", .green)
                case .refreshing: return ("Refreshing", .blue)
                case .error: return ("Error", .red)
                }
            }()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .foregroundStyle(color)
                    .font(.caption)
            }
        }
    }

    private func runOAuthSignInAction() {
        let alias = trimmedAlias
        prepareLogSession(for: alias)
        appendSetupLog(level: .info, message: "Starting OAuth sign-in flow for \"\(alias.isEmpty ? "unnamed" : alias)\".")

        guard requiresOAuth, let draft = synchronizeDraftServer() else {
            oauthActionMessage = "Configure base URL and OAuth header before signing in."
            appendSetupLog(level: .error, message: "Sign-in aborted: missing Authorization header sourced from OAuth tokens.")
            return
        }
        draft.baseURL = normalizedBaseURL
        guard !(draft.baseURL?.isEmpty ?? true) else {
            oauthActionMessage = "Configure base URL and OAuth header before signing in."
            appendSetupLog(level: .error, message: "Sign-in aborted: base URL is required.")
            return
        }

        isPerformingOAuthAction = true
        oauthActionMessage = nil
        Task { @MainActor in
            defer { isPerformingOAuthAction = false }
            guard applyManualCredentials(to: draft) else {
                appendSetupLog(level: .error, message: "Manual OAuth client credentials required before continuing.")
                return
            }
            appendSetupLog(level: .info, message: "Running OAuth discovery at \(draft.baseURL ?? "unknown base URL").")
            await OAuthService.shared.runAuthDiscovery(server: draft, wwwAuthenticate: nil)
            guard let configuration = draft.oauthConfiguration else {
                oauthActionMessage = "Discovery failed to find OAuth metadata for this server."
                draft.oauthStatus = .error
                appendSetupLog(level: .error, message: "Discovery failed to find OAuth metadata for this server.")
                return
            }
            if useManualOAuthClient {
                configuration.clientId = manualClientId.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedSecret = manualClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.clientSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
                configuration.clientSource = .manual
                appendSetupLog(level: .info, message: "Using manual OAuth client credentials.")
            } else {
                configuration.clientSource = .dynamic
            }
            appendSetupLog(level: .info, message: "Launching OAuth authorization flow.")
            await OAuthService.shared.startAuthorizationFlow(server: draft, configuration: configuration)
            manualClientId = configuration.clientId ?? manualClientId
            manualClientSecret = configuration.clientSecret ?? manualClientSecret
            if draft.oauthStatus == .error {
                let message = draft.oauthDiagnostics.lastErrorDescription ?? "OAuth sign-in failed."
                oauthActionMessage = message
                appendSetupLog(level: .error, message: "OAuth sign-in failed: \(message)")
                try? activeModelContext.save()
                return
            }
            appendSetupLog(level: .info, message: "OAuth authorization flow initiated. Awaiting user completion.")
            try? activeModelContext.save()
        }
    }

    private func refreshOAuthTokenAction() {
        guard requiresOAuth, let draft = synchronizeDraftServer() else { return }
        isPerformingOAuthAction = true
        oauthActionMessage = nil
        Task { @MainActor in
            defer { isPerformingOAuthAction = false }
            _ = await OAuthService.shared.refreshAccessToken(for: draft, announce: true)
            try? activeModelContext.save()
        }
    }

    private func disconnectOAuthAction() {
        guard let draft = oauthDraftServer, let state = draft.oauthState else { return }
        state.serializedAuthState = Data()
        state.isActive = false
        state.lastTokenRefresh = nil
        draft.oauthStatus = .unauthorized
        oauthActionMessage = "Disconnected. Sign in again to reconnect."
    }

    @MainActor
    private func prepareLogSession(for alias: String) {
        let normalizedAlias = normalizedAliasForLogs(alias)
        if setupLogAlias != normalizedAlias {
            clearSetupLogs(deletePersisted: true)
            setupLogAlias = normalizedAlias
        }
    }

    @MainActor
    private func appendSetupLog(level: LogLevel, message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        let entry = LogEntry(project: project,
                             timestamp: Date(),
                             level: level,
                             category: currentSetupCategory,
                             message: trimmedMessage)
        activeModelContext.insert(entry)
        do {
            try activeModelContext.save()
            persistenceError = nil
        } catch {
            persistenceError = "Failed to persist setup log: \(error.localizedDescription)"
        }
        setupLogEntries.append(SetupLogEntry(entry: entry))
    }

    @MainActor
    private func clearSetupLogs(deletePersisted: Bool) {
        if deletePersisted {
            for wrapper in setupLogEntries {
                if let context = wrapper.entry.modelContext {
                    context.delete(wrapper.entry)
                }
            }
            do {
                if activeModelContext.hasChanges {
                    try activeModelContext.save()
                    persistenceError = nil
                }
            } catch {
                persistenceError = "Failed to clear setup logs: \(error.localizedDescription)"
            }
        }
        setupLogEntries.removeAll()
        setupSessionID = UUID()
        if deletePersisted {
            setupLogAlias = ""
        }
    }

    @MainActor
    private func promoteSetupLogs(to alias: String) {
        guard !setupLogEntries.isEmpty else { return }
        let category = "server.\(normalizedAliasForLogs(alias))"
        for wrapper in setupLogEntries {
            wrapper.entry.category = category
        }
        setupLogEntries.removeAll()
        setupLogAlias = ""
        setupSessionID = UUID()
    }

    private var currentSetupCategory: String {
        let aliasComponent = setupLogAlias.isEmpty ? "unnamed" : setupLogAlias
        return "setup.\(aliasComponent).\(setupSessionID.uuidString)"
    }

    private func normalizedAliasForLogs(_ alias: String) -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unnamed" }
        return trimmed.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
    }

    private func levelColor(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .info: return .blue
        case .debug: return .gray
        }
    }

    private struct SetupLogEntry: Identifiable {
        let id = UUID()
        let entry: LogEntry

        var timestamp: Date { entry.timestamp }
        var level: LogLevel { entry.level }
        var message: String { entry.message }
    }

    private func displayStatus(for status: OAuthStatus, isActive: Bool, isPerforming: Bool) -> OAuthStatus {
        if status == .refreshing && !isPerforming {
            return isActive ? .authorized : .unauthorized
        }
        return status
    }
}

#if DEBUG
extension AddServerSheet {
    @MainActor
    mutating func triggerTestConnectionForTesting() async {
        await testConnectionAsync()
    }

    var headersStateForTesting: [HeaderBinding] {
        get { headersState }
        set { headersState = newValue }
    }
    var oauthActionMessageForTesting: String? {
        get { oauthActionMessage }
        set { oauthActionMessage = newValue }
    }
    var testResultForTesting: HealthStatus {
        get { testResult }
        set { testResult = newValue }
    }
    var useManualOAuthClientForTesting: Bool {
        get { useManualOAuthClient }
        set { useManualOAuthClient = newValue }
    }
    var manualClientIdForTesting: String {
        get { manualClientId }
        set { manualClientId = newValue }
    }
    var aliasForTesting: String {
        get { alias }
        set { alias = newValue }
    }
    var baseURLForTesting: String {
        get { baseURL }
        set { baseURL = newValue }
    }
    var kindForTesting: ServerKind { kind }
}
#endif
