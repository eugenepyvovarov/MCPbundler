//
//  LogsView.swift
//  MCP Bundler
//
//  Displays log entries for a project with pagination and refresh controls.
//

import SwiftUI
import SwiftData

struct LogsView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @State private var currentPage: Int = 1
    @State private var autoRefresh: Bool = false
    @State private var refreshTimer: Timer?
    @State private var lastRefreshed: Date = .now
    @State private var showingDeleteConfirmation = false
    @State private var displayedLogs: [LogEntry] = []

    private let logsPerPage = 100
    private enum MCPClientLogMetadataKeys {
        static let name = "mcp_client_name"
        static let version = "mcp_client_version"
        static let unknown = "unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with controls
            HStack {
                Text("Logs")
                    .font(.headline)

                Spacer()

                // Auto-refresh toggle
                Toggle("Auto Refresh", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: autoRefresh) { oldValue, newValue in
                        if newValue {
                            startAutoRefresh()
                        } else {
                            stopAutoRefresh()
                        }
                    }

                // Manual refresh button
                Button(action: refreshLogs) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete Logs", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }

            // Last refreshed info
            Text("Last refreshed: \(lastRefreshed.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Logs table
            if logsForCurrentPage.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No logs found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(logsForCurrentPage) {
                    TableColumn("Timestamp") { log in
                        Text(log.timestamp.mcpShortDateTime())
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Level") { log in
                        Text(log.level.rawValue.uppercased())
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(levelColor(for: log.level).opacity(0.2))
                            .foregroundStyle(levelColor(for: log.level))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Category") { log in
                        Text(log.category)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("Client") { log in
                        Text(clientDisplayName(for: log))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Message") { log in
                        Text(log.message)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(8)
                            .truncationMode(.tail)
                    }
                }
                .frame(minHeight: 400)

                // Pagination controls
                if totalPages > 1 {
                    HStack {
                        Spacer()

                        Button("Previous") {
                            if currentPage > 1 {
                                currentPage -= 1
                            }
                        }
                        .disabled(currentPage <= 1)
                        .buttonStyle(.bordered)

                        Text("Page \(currentPage) of \(totalPages)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 100)

                        Button("Next") {
                            if currentPage < totalPages {
                                currentPage += 1
                            }
                        }
                        .disabled(currentPage >= totalPages)
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding()
        .onAppear {
            refreshLogs()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onChange(of: project.persistentModelID) { _, _ in
            // When switching projects, refresh and re-arm auto-refresh if enabled
            refreshLogs()
            stopAutoRefresh()
            if autoRefresh {
                startAutoRefresh()
            }
        }
        .alert("Delete All Logs?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteAllLogs()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes all log entries for \"\(project.name)\" permanently.")
        }
    }

    // MARK: - Computed Properties

    private var totalLogs: Int {
        displayedLogs.count
    }

    private var totalPages: Int {
        max(1, (totalLogs + logsPerPage - 1) / logsPerPage)
    }

    private var logsForCurrentPage: [LogEntry] {
        let startIndex = (currentPage - 1) * logsPerPage
        let endIndex = min(startIndex + logsPerPage, totalLogs)
        guard startIndex < totalLogs else { return [] }
        return Array(displayedLogs[startIndex..<endIndex])
    }

    // MARK: - Methods

    private func levelColor(for level: LogLevel) -> Color {
        switch level {
        case .error:
            return .red
        case .info:
            return .blue
        case .debug:
            return .gray
        }
    }

    private func refreshLogs() {
        let fetched = project.logs.sorted { $0.timestamp > $1.timestamp }
        displayedLogs = fetched
        lastRefreshed = .now

        if currentPage > totalPages {
            currentPage = max(1, totalPages)
        }
    }

    private func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshLogs()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func deleteAllLogs() {
        let logs = project.logs
        for log in logs {
            modelContext.delete(log)
        }
        project.logs.removeAll()

        do {
            try modelContext.save()
            displayedLogs.removeAll()
            refreshLogs()
        } catch {
            print("Failed to delete logs: \(error)")
        }
    }

    private func createTestLog() {
        // Create a test log entry directly
        let testLog = LogEntry(
            project: project,
            timestamp: Date(),
            level: .info,
            category: "test",
            message: "This is a test log entry created at \(Date().mcpShortDateTime())"
        )

        // Insert into model context
        modelContext.insert(testLog)

        do {
            try modelContext.save()
            print("✅ Successfully created test log!")
            refreshLogs()
        } catch {
            print("❌ Failed to save test log: \(error)")
        }
    }

    private func clientDisplayName(for entry: LogEntry) -> String {
        guard let metadata = entry.metadata,
              let decoded = decodeMetadata(metadata),
              let rawName = decoded[MCPClientLogMetadataKeys.name] as? String else {
            return MCPClientLogMetadataKeys.unknown
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return MCPClientLogMetadataKeys.unknown }

        if name == MCPClientLogMetadataKeys.unknown {
            return MCPClientLogMetadataKeys.unknown
        }

        if let rawVersion = decoded[MCPClientLogMetadataKeys.version] as? String {
            let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty {
                return "\(name) (\(version))"
            }
        }

        return name
    }

    private func decodeMetadata(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
