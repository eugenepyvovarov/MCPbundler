//
//  ProjectWorkspaceMockupView.swift
//  MCP Bundler
//
//  Mockup window for exploring the project-centric workspace layout.
//

import SwiftUI

struct ProjectWorkspaceMockupView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab = "Project1"
    @State private var mcpScope: MockupScope = .global
    @State private var skillScope: MockupScope = .global
    @State private var selectedCodeAction: MockupCodeAction = .codex

    private let tabs = ["Project1", "P2", "P3"]

    private let globalServerRows: [MockupServerRow] = [
        .group(name: "1. Docs", detail: "3 servers", isEnabled: true, health: .healthy),
        .server(name: "apple-docs", tools: 2, activeTools: 2, health: .healthy, isEnabled: true),
        .server(name: "context7", tools: 2, activeTools: 2, health: .healthy, isEnabled: true),
        .server(name: "openai-docs", tools: 5, activeTools: 5, health: .healthy, isEnabled: true),
    ]

    private let projectServerRows: [MockupServerRow] = [
        .group(name: "2. Dev tools", detail: "1 server", isEnabled: false, health: .degraded),
        .server(name: "do-droplets", tools: 43, activeTools: 0, health: .healthy, isEnabled: false),
        .group(name: "3. Browser", detail: "1 server", isEnabled: true, health: .healthy),
        .server(name: "chromedev", tools: 4, activeTools: 4, health: .healthy, isEnabled: true),
    ]

    private let globalSkillRows: [MockupSkillRow] = [
        .group(name: "1. Everyday", detail: "2 skills", enabled: true, codex: true, other: false),
        .skill(name: "obsidian-vault-manager", description: "Manage local vault notes.", enabled: true, codex: true, other: false),
        .skill(name: "swiftui-ui-patterns", description: "SwiftUI layout patterns.", enabled: true, codex: true, other: false),
        .group(name: "2. Others", detail: "1 skill", enabled: false, codex: false, other: false),
        .skill(name: "release-notes", description: "Draft changelog summaries.", enabled: false, codex: false, other: true),
    ]

    private let projectSkillRows: [MockupSkillRow] = [
        .group(name: "3. MCPBundler", detail: "1 skill", enabled: true, codex: true, other: false),
        .skill(name: "mcp-bundler", description: "Project-specific helpers.", enabled: true, codex: true, other: false),
        .group(name: "4. Repo tools", detail: "1 skill", enabled: false, codex: false, other: false),
        .skill(name: "deploy-checks", description: "Preflight release checks.", enabled: false, codex: false, other: true),
    ]

    private var activeSkillRows: [MockupSkillRow] {
        skillScope == .global ? globalSkillRows : projectSkillRows
    }

    private var activeServerRows: [MockupServerRow] {
        mcpScope == .global ? globalServerRows : projectServerRows
    }

    var body: some View {
        ZStack {
            MockupBackground()
            VStack(spacing: 12) {
                headerRow
                infoRow
                codeActions
                skillsSection
                mcpSection
            }
            .padding(20)
        }
        .frame(minWidth: 1180, minHeight: 720)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            MockupGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    MockupSegmentedControl(title: "Projects",
                                           selection: $selectedTab,
                                           options: tabs,
                                           controlSize: .large) { tab in
                        tab
                    }
                    .frame(maxWidth: 380)

                    Button(action: {}) {
                        Image(systemName: "plus")
                            .font(.callout.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .mockupGlassButtonStyle(compact: true)
                }
            }

            Spacer()

            MockupGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Select Project") {
                        openWindow(id: "projectSelectorMockup")
                    }
                    .mockupGlassButtonStyle()

                    Button("Settings") {}
                        .mockupGlassButtonStyle()
                }
            }
        }
    }

    private var infoRow: some View {
        MockupGlassGroup(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MockupCard {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Project title", text: .constant("Project title"))
                            .textFieldStyle(.roundedBorder)
                        Label("/project/folder", systemImage: "folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MockupCard(title: "MCP Summary") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Preferred bundle") {
                            Text("Default")
                        }
                        LabeledContent("Active MCPs") {
                            Text("12")
                        }
                        LabeledContent("Status") {
                            HealthBadge(status: .healthy)
                                .font(.caption)
                        }
                    }
                    .font(.callout)
                }
                .frame(width: 260)
            }
        }
    }

    private var codeActions: some View {
        MockupCard {
            MockupGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    MockupSegmentedControl(title: "Code Actions",
                                           selection: $selectedCodeAction,
                                           options: MockupCodeAction.allCases,
                                           controlSize: .regular) { action in
                        action.title
                    }
                    .frame(maxWidth: 420, alignment: .leading)

                    Button(action: {}) {
                        Image(systemName: "plus")
                            .font(.callout.weight(.semibold))
                            .frame(width: 26, height: 26)
                    }
                    .mockupGlassButtonStyle(compact: true)
                }
            }
        }
    }

    private var skillsSection: some View {
        MockupSectionCard(title: "Skills", scope: $skillScope) {
            MockupSkillsTable(rows: activeSkillRows)
        }
    }

    private var mcpSection: some View {
        MockupSectionCard(title: "MCP", scope: $mcpScope) {
            MockupServersTable(rows: activeServerRows)
        }
    }
}

struct ProjectSelectorMockupView: View {
    @Environment(\.dismiss) private var dismiss

    private let projects = [
        MockupProject(title: "Title", folder: "/folder"),
        MockupProject(title: "Title 2", folder: "/folder 2"),
    ]

    var body: some View {
        ZStack {
            MockupBackground()
            VStack(alignment: .leading, spacing: 16) {
                Text("Select Project")
                    .font(.headline)

                MockupCard {
                    List(projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.title)
                                .font(.headline)
                            Text(project.folder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180)
                    .mockupListBackground()
                }

                Spacer()

                HStack {
                    Button("New") {}
                        .mockupGlassButtonStyle()
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .mockupGlassButtonStyle()
                }
            }
            .padding(20)
        }
        .frame(minWidth: 320, minHeight: 360)
    }
}

private struct MockupProject: Identifiable {
    let id = UUID()
    let title: String
    let folder: String
}

private enum MockupScope: String, CaseIterable, Identifiable {
    case global
    case project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global:
            return "Global"
        case .project:
            return "Project"
        }
    }
}

private enum MockupCodeAction: String, CaseIterable, Identifiable {
    case codex
    case openCode
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .openCode:
            return "Open Code"
        case .claudeCode:
            return "Claude Code"
        }
    }
}

private enum MockupLayout {
    static let cardCornerRadius: CGFloat = 16
    static let chipCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let segmentedCornerRadiusLarge: CGFloat = 18
    static let segmentedCornerRadiusSmall: CGFloat = 14
    static let serverToggleWidth: CGFloat = 42
    static let serverNameWidth: CGFloat = 240
    static let serverCountWidth: CGFloat = 60
    static let serverActiveWidth: CGFloat = 80
    static let serverStatusWidth: CGFloat = 110
    static let serverActionWidth: CGFloat = 70
    static let skillToggleWidth: CGFloat = 50
    static let skillNameWidth: CGFloat = 220
    static let skillActionWidth: CGFloat = 70
}

private enum MockupPalette {
    static let glassTintSoft = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.12)
}

private struct MockupBackground: View {
    var body: some View {
        ZStack {
            Color(.windowBackgroundColor)
            LinearGradient(colors: [
                Color.white.opacity(0.05),
                Color.clear,
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [
                Color.black.opacity(0.12),
                Color.clear,
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

private struct MockupCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(MockupLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mockupGlass(tint: MockupPalette.glassTintSoft,
                     cornerRadius: MockupLayout.cardCornerRadius,
                     interactive: false)
        .overlay(MockupRoundedStroke(cornerRadius: MockupLayout.cardCornerRadius,
                                     color: Color.secondary.opacity(0.2)))
    }
}

private struct MockupSectionCard<Content: View>: View {
    let title: String
    @Binding var scope: MockupScope
    let content: Content

    init(title: String, scope: Binding<MockupScope>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._scope = scope
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                MockupSegmentedControl(title: "Scope",
                                       selection: $scope,
                                       options: MockupScope.allCases,
                                       controlSize: .small) { option in
                    option.title
                }
                .frame(width: 200)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MockupSegmentedControl<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let controlSize: ControlSize
    let label: (Option) -> String

    private var isLarge: Bool {
        controlSize == .large || controlSize == .regular
    }

    private var cornerRadius: CGFloat {
        isLarge ? MockupLayout.segmentedCornerRadiusLarge : MockupLayout.segmentedCornerRadiusSmall
    }

    private var verticalPadding: CGFloat {
        isLarge ? 6 : 4
    }

    private var horizontalPadding: CGFloat {
        isLarge ? 8 : 6
    }

    init(title: String,
         selection: Binding<Option>,
         options: [Option],
         controlSize: ControlSize = .small,
         label: @escaping (Option) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.controlSize = controlSize
        self.label = label
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(controlSize)
        .labelsHidden()
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .mockupGlass(tint: MockupPalette.glassTintSoft,
                     cornerRadius: cornerRadius,
                     interactive: true)
        .overlay(MockupRoundedStroke(cornerRadius: cornerRadius,
                                     color: Color.secondary.opacity(0.25)))
    }
}

private struct MockupServersTable: View {
    let rows: [MockupServerRow]

    var body: some View {
        Table(rows) {
            TableColumn("") { row in
                Toggle("", isOn: .constant(row.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .width(min: MockupLayout.serverToggleWidth,
                   ideal: MockupLayout.serverToggleWidth,
                   max: MockupLayout.serverToggleWidth)

            TableColumn("Name") { row in
                serverNameCell(row)
            }
            .width(min: MockupLayout.serverNameWidth,
                   ideal: MockupLayout.serverNameWidth)

            TableColumn("Tools") { row in
                serverCountCell(text: row.toolsText)
            }
            .width(min: MockupLayout.serverCountWidth,
                   ideal: MockupLayout.serverCountWidth)

            TableColumn("Active Tools") { row in
                serverCountCell(text: row.activeToolsText)
            }
            .width(min: MockupLayout.serverActiveWidth,
                   ideal: MockupLayout.serverActiveWidth)

            TableColumn("Status") { row in
                HealthBadge(status: row.health)
                    .font(.caption)
            }
            .width(min: MockupLayout.serverStatusWidth,
                   ideal: MockupLayout.serverStatusWidth)

            TableColumn("Actions") { _ in
                MockupRowActions()
            }
            .width(min: MockupLayout.serverActionWidth,
                   ideal: MockupLayout.serverActionWidth)
        }
        .font(.callout)
        .frame(minHeight: 170)
    }

    @ViewBuilder
    private func serverNameCell(_ row: MockupServerRow) -> some View {
        switch row.kind {
        case .group:
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(row.name)
                    .font(.headline)
                Spacer()
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .server:
            HStack(spacing: 6) {
                Text(row.name)
                    .foregroundStyle(row.isEnabled ? Color.primary : Color.secondary)
                Spacer()
            }
        }
    }

    private func serverCountCell(text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MockupSkillsTable: View {
    let rows: [MockupSkillRow]

    var body: some View {
        Table(rows) {
            TableColumn("Enabled") { row in
                Toggle("", isOn: .constant(row.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .width(min: MockupLayout.skillToggleWidth,
                   ideal: MockupLayout.skillToggleWidth,
                   max: MockupLayout.skillToggleWidth)

            TableColumn("Codex") { row in
                Toggle("", isOn: .constant(row.codex))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .width(min: MockupLayout.skillToggleWidth,
                   ideal: MockupLayout.skillToggleWidth,
                   max: MockupLayout.skillToggleWidth)

            TableColumn("Other") { row in
                Toggle("", isOn: .constant(row.other))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .width(min: MockupLayout.skillToggleWidth,
                   ideal: MockupLayout.skillToggleWidth,
                   max: MockupLayout.skillToggleWidth)

            TableColumn("Display Name") { row in
                skillNameCell(row)
            }
            .width(min: MockupLayout.skillNameWidth,
                   ideal: MockupLayout.skillNameWidth)

            TableColumn("Description") { row in
                Text(row.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("Actions") { _ in
                MockupRowActions()
            }
            .width(min: MockupLayout.skillActionWidth,
                   ideal: MockupLayout.skillActionWidth)
        }
        .font(.callout)
        .frame(minHeight: 190)
    }

    @ViewBuilder
    private func skillNameCell(_ row: MockupSkillRow) -> some View {
        switch row.kind {
        case .group:
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(row.name)
                    .font(.headline)
                Spacer()
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .skill:
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(row.name)
                Spacer()
            }
        }
    }
}

private struct MockupRowActions: View {
    var body: some View {
        HStack(spacing: 6) {
            Button(action: {}) {
                Label("Edit", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)

            Button(action: {}) {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }
}

private struct MockupRoundedStroke: View {
    let cornerRadius: CGFloat
    var color: Color = MockupPalette.stroke

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(color, lineWidth: 1)
    }
}

private struct MockupGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct MockupServerRow: Identifiable {
    enum Kind {
        case group
        case server
    }

    let id = UUID()
    let kind: Kind
    let name: String
    let tools: Int?
    let activeTools: Int?
    let health: HealthStatus
    let detail: String?
    let isEnabled: Bool

    static func group(name: String,
                      detail: String,
                      isEnabled: Bool,
                      health: HealthStatus) -> MockupServerRow {
        MockupServerRow(kind: .group,
                        name: name,
                        tools: nil,
                        activeTools: nil,
                        health: health,
                        detail: detail,
                        isEnabled: isEnabled)
    }

    static func server(name: String,
                       tools: Int,
                       activeTools: Int,
                       health: HealthStatus,
                       isEnabled: Bool) -> MockupServerRow {
        MockupServerRow(kind: .server,
                        name: name,
                        tools: tools,
                        activeTools: activeTools,
                        health: health,
                        detail: nil,
                        isEnabled: isEnabled)
    }

    var toolsText: String {
        if let tools { return "\(tools)" }
        return detail ?? ""
    }

    var activeToolsText: String {
        if let activeTools { return "\(activeTools)" }
        return ""
    }
}

private struct MockupSkillRow: Identifiable {
    enum Kind {
        case group
        case skill
    }

    let id = UUID()
    let kind: Kind
    let name: String
    let description: String?
    let enabled: Bool
    let codex: Bool
    let other: Bool
    let detail: String?

    static func group(name: String,
                      detail: String,
                      enabled: Bool,
                      codex: Bool,
                      other: Bool) -> MockupSkillRow {
        MockupSkillRow(kind: .group,
                       name: name,
                       description: nil,
                       enabled: enabled,
                       codex: codex,
                       other: other,
                       detail: detail)
    }

    static func skill(name: String,
                      description: String,
                      enabled: Bool,
                      codex: Bool,
                      other: Bool) -> MockupSkillRow {
        MockupSkillRow(kind: .skill,
                       name: name,
                       description: description,
                       enabled: enabled,
                       codex: codex,
                       other: other,
                       detail: nil)
    }

    var descriptionText: String {
        if let description { return description }
        return detail ?? ""
    }
}

private extension View {
    @ViewBuilder
    func mockupGlass(tint: Color,
                     cornerRadius: CGFloat,
                     interactive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.tint(tint).interactive(),
                                 in: .rect(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.glassEffect(.regular.tint(tint),
                                 in: .rect(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self.background(.thinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func mockupGlassButtonStyle(compact: Bool = false) -> some View {
        let verticalPadding: CGFloat = compact ? 4 : 6
        let horizontalPadding: CGFloat = compact ? 10 : 12
        let radius: CGFloat = compact ? 10 : MockupLayout.chipCornerRadius

        self.buttonStyle(.plain)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .mockupGlass(tint: MockupPalette.glassTintSoft,
                         cornerRadius: radius,
                         interactive: true)
            .overlay(MockupRoundedStroke(cornerRadius: radius))
    }

    @ViewBuilder
    func mockupListBackground() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

#Preview {
    ProjectWorkspaceMockupView()
}

#Preview("Selector") {
    ProjectSelectorMockupView()
}
