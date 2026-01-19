//
//  HeadlessConnectionView.swift
//  MCP Bundler
//
//  Restores the compact headless configuration block with a client selector.
//

import SwiftUI
import AppKit

struct HeadlessConnectionView: View {
    private let clients: [ClientInstallInstruction]
    private let universalCommand: String
    private let universalJSON: String
    private let detailHeight: CGFloat = 300
    private let contentPadding = EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)

    @State private var selectedClientID: String
    @State private var copyConfirmation: String?
    @AppStorage("headlessConnectionIsExpanded") private var isExpanded: Bool = true

    init(executablePath: String, bundle: Bundle = .main) {
        let instructions = ClientInstallInstructionLoader.loadClients(executablePath: executablePath, bundle: bundle)

        // Ensure the generic/default client (if present) is listed first.
        self.clients = instructions.sorted { lhs, rhs in
            if lhs.id == "default" { return true }
            if rhs.id == "default" { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        self.universalCommand = HeadlessConnectionView.makeUniversalCommand(for: executablePath, defaultAction: instructions.first(where: { $0.id == "default" })?.primaryAction.shellSnippet)
        self.universalJSON = HeadlessConnectionView.makeUniversalJSON(for: executablePath)

        _selectedClientID = State(initialValue: clients.first?.id ?? instructions.first?.id ?? "default")
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Button(action: toggleExpansion) {
                    HeadlessServerSummaryLabel(clientCount: clients.count, isExpanded: isExpanded)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                        .padding(.horizontal, 20)
                        .opacity(0.25)

                    VStack(alignment: .leading, spacing: 12) {
                        headerRow

                        Divider()

                        if let client = selectedClient {
                            ScrollView(.vertical) {
                                ClientInstructionDetail(
                                    client: client,
                                    universalCommand: universalCommand,
                                    universalJSON: universalJSON,
                                    copyHandler: copyToPasteboard,
                                    linkHandler: openLink
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 4)
                            }
                            .scrollIndicators(.automatic)
                            .scrollIndicatorsFlash(onAppear: true)
                            .frame(height: detailHeight)
                        } else {
                            Text("No client instructions available.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(contentPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06))
            )
            .shadow(color: Color.black.opacity(0.05), radius: 18, y: 10)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            if let message = copyConfirmation {
                VStack {
                    CopyToast(message: message)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: copyConfirmation)
    }
}

// MARK: - Subviews & Helpers

private extension HeadlessConnectionView {
    var selectedClient: ClientInstallInstruction? {
        clients.first(where: { $0.id == selectedClientID })
    }

    var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Expose MCP Bundler as a stdio MCP server.")
                    .font(.headline)
                Text("Choose a client to see tailored installation steps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !clients.isEmpty {
                Picker("Client", selection: $selectedClientID) {
                    ForEach(clients) { client in
                        Text(client.displayName).tag(client.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)
                .labelsHidden()
            }
        }
    }

    func toggleExpansion() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let originalFrame = window?.frame

        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }

        guard let window, let frame = originalFrame else { return }
        DispatchQueue.main.async {
            window.setFrame(frame, display: false, animate: false)
        }
    }

    func copyToPasteboard(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        copyConfirmation = "\(label) copied to clipboard"

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copyConfirmation == "\(label) copied to clipboard" {
                withAnimation {
                    copyConfirmation = nil
                }
            }
        }
    }

    func openLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func makeUniversalCommand(for executablePath: String, defaultAction: String?) -> String {
        let needsQuoting = executablePath.contains(" ")
        let quotedPath = needsQuoting ? "\"\(executablePath)\"" : executablePath

        if var snippet = defaultAction, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if needsQuoting {
                snippet = replacingUnquotedExecutablePath(in: snippet, executablePath: executablePath, quotedPath: quotedPath)
            }
            return snippet
        }

        return "\(quotedPath) --stdio-server"
    }

    private static func replacingUnquotedExecutablePath(in snippet: String, executablePath: String, quotedPath: String) -> String {
        var updatedSnippet = snippet
        var searchRange = updatedSnippet.startIndex..<updatedSnippet.endIndex

        while let range = updatedSnippet.range(of: executablePath, options: [], range: searchRange) {
            let precedingIndex = range.lowerBound > updatedSnippet.startIndex ? updatedSnippet.index(before: range.lowerBound) : nil
            let followingIndex = range.upperBound < updatedSnippet.endIndex ? range.upperBound : nil

            let precedingChar: Character? = precedingIndex.map { updatedSnippet[$0] }
            let followingChar: Character? = followingIndex.map { updatedSnippet[$0] }

            let isQuoted = (precedingChar == "\"" && followingChar == "\"") || (precedingChar == "'" && followingChar == "'")
            let hasWordBoundaryBefore = precedingChar == nil || precedingChar?.isWhitespace == true
            let hasWordBoundaryAfter = followingChar == nil || followingChar?.isWhitespace == true

            if !isQuoted && hasWordBoundaryBefore && hasWordBoundaryAfter {
                let lowerBoundOffset = updatedSnippet.distance(from: updatedSnippet.startIndex, to: range.lowerBound)
                updatedSnippet.replaceSubrange(range, with: quotedPath)
                let replacementEnd = updatedSnippet.index(updatedSnippet.startIndex, offsetBy: lowerBoundOffset + quotedPath.count)
                searchRange = replacementEnd..<updatedSnippet.endIndex
            } else {
                searchRange = range.upperBound..<updatedSnippet.endIndex
            }
        }

        return updatedSnippet
    }

    static func makeUniversalJSON(for executablePath: String) -> String {
        """
        {
          "mcp-bundler": {
            "command": "\(executablePath)",
            "args": ["--stdio-server"],
            "env": {}
          }
        }
        """
    }
}

private struct HeadlessServerSummaryLabel: View {
    let clientCount: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.28),
                                Color.accentColor.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                Image(systemName: "terminal")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .shadow(color: Color.accentColor.opacity(0.25), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("Headless MCP Server")
                    .font(.headline)
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if clientCount > 0 {
                Text("\(clientCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .accessibilityLabel("\(clientCount) supported clients")
            }

            Image(systemName: "chevron.down")
                .font(.headline.weight(.semibold))
                .rotationEffect(isExpanded ? .degrees(180) : .degrees(0))
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
        }
        .contentShape(Rectangle())
    }

    private var secondaryText: String {
        if clientCount == 0 {
            return "Add a client recipe to publish setup notes."
        }
        if clientCount == 1 {
            return "Includes installation guidance for one client."
        }
        return "Includes installation guidance for \(clientCount) clients."
    }
}

// MARK: - Detail View

private struct ClientInstructionDetail: View {
    let client: ClientInstallInstruction
    let universalCommand: String
    let universalJSON: String
    let copyHandler: (String, String) -> Void
    let linkHandler: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = summaryText {
                summary
            }

            switch client.primaryAction.type {
            case .command:
                commandSection
            case .gui:
                guiSection
            case .deeplink:
                deeplinkSection
            }

            configFilesSection
            notesSection
            docsLink
        }
    }

    private var summaryText: Text? {
        if let uxSnippet = client.primaryAction.uxSnippet,
           let attributed = try? AttributedString(markdown: uxSnippet) {
            return Text(attributed)
        }
        return nil
    }

    @ViewBuilder
    private var commandSection: some View {
        if let shellSnippet = client.primaryAction.shellSnippet {
            SnippetView(
                title: "Command",
                snippet: shellSnippet,
                copyLabel: "Command",
                copyAction: copyHandler
            )
        }

        if client.id == "default" {
            SnippetView(
                title: "Universal JSON",
                snippet: universalJSON,
                copyLabel: "JSON",
                copyAction: copyHandler
            )
        } else if let codeSnippet = client.primaryAction.codeSnippet {
            SnippetView(
                title: "Configuration",
                snippet: codeSnippet,
                copyLabel: "Configuration",
                copyAction: copyHandler
            )
        }
    }

    @ViewBuilder
    private var guiSection: some View {
        if let codeSnippet = client.primaryAction.codeSnippet {
            SnippetView(
                title: "Configuration",
                snippet: codeSnippet,
                copyLabel: "Configuration",
                copyAction: copyHandler
            )
        }
    }

    @ViewBuilder
    private var deeplinkSection: some View {
        if let urlString = client.primaryAction.deeplinkUrl,
           let url = URL(string: urlString) {
            Button {
                linkHandler(url)
            } label: {
                Label(client.primaryAction.deeplinkLabel ?? "Open link", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var configFilesSection: some View {
        if !client.configFiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(client.configFiles) { config in
                    ConfigSnippetView(
                        configFile: config,
                        copyAction: copyHandler
                    )
                    if config != client.configFiles.last {
                        Divider().padding(.horizontal, -4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if !client.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.subheadline)
                ForEach(client.notes, id: \.self) { note in
                    Text("• \(note)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var docsLink: some View {
        if let docs = client.docsUrl, let url = URL(string: docs) {
            Link(destination: url) {
                Label("View documentation", systemImage: "book")
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Snippet Rendering

private struct SnippetView: View {
    let title: String
    let snippet: String
    let copyLabel: String
    let copyAction: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                InlineCopyButton(copyLabel: copyLabel, snippet: snippet, copyAction: copyAction)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(snippet)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }
        }
    }
}

private struct ConfigSnippetView: View {
    let configFile: ClientInstallInstruction.ConfigFile
    let copyAction: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(configFile.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(configFile.format.uppercased())
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                    )
            }

            if let snippet = configFile.snippet {
                SnippetView(
                    title: "Snippet",
                    snippet: snippet,
                    copyLabel: "Snippet",
                    copyAction: copyAction
                )
            } else if let importFormat = configFile.importFormat {
                Text(importFormat.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if importFormat.type == .regex, let pattern = importFormat.pattern {
                    SnippetView(
                        title: "Import Pattern",
                        snippet: pattern,
                        copyLabel: "Pattern",
                        copyAction: copyAction
                    )
                }
            }
        }
    }
}

// MARK: - Copy Helpers

private struct InlineCopyButton: View {
    let copyLabel: String
    let snippet: String
    let copyAction: (String, String) -> Void

    var body: some View {
        Button {
            copyAction(snippet, copyLabel)
        } label: {
            Label("Copy \(copyLabel)", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
    }
}

private struct CopyToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(message)
                .foregroundStyle(.white)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor)
        )
        .shadow(radius: 2, y: 1)
    }
}

// MARK: - Preview

#Preview {
    HeadlessConnectionView(
        executablePath: "/Applications/MCPBundler.app/Contents/MacOS/MCPBundler",
        bundle: .main
    )
    .padding()
    .frame(width: 600)
}
