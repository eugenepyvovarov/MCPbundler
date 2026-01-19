//
//  SkillSyncLocationsView.swift
//  MCP Bundler
//
//  Manages global skills sync locations.
//

import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct SkillSyncLocationsView: View {
    enum DisplayStyle {
        case standalone
        case embedded
    }

    @Environment(\.modelContext) private var modelContext

    @Query private var locations: [SkillSyncLocation]

    let displayStyle: DisplayStyle

    @State private var pinError: String?
    @State private var addError: String?
    @State private var showingCustomNameSheet = false
    @State private var customLocationRoot: URL?
    @State private var customLocationName: String = ""
    @State private var customNameError: String?
    @State private var locationToRename: SkillSyncLocation?
    @State private var renameLocationName: String = ""
    @State private var renameError: String?
    @State private var locationToDelete: SkillSyncLocation?
    @State private var locationsTableView: NSTableView?

    init(displayStyle: DisplayStyle = .standalone) {
        self.displayStyle = displayStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            header

            if displayStyle == .embedded {
                Text("Choose which folders MCP Bundler manages for native skills.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let pinError {
                Text(pinError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let addError {
                Text(addError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text("Individual toggle for separate control in the skills list. Max 3 locations; remaining enabled locations are grouped under Other.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Table(sortedLocations) {
                TableColumn("Enabled") { location in
                    HStack(spacing: 0) {
                        Toggle(isOn: managedBinding(for: location)) { EmptyView() }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer()
                    }
                }
                .width(min: 70, ideal: 70, max: 80)

                TableColumn("Individual toggle") { (location: SkillSyncLocation) in
                    HStack(spacing: 0) {
                        Toggle(isOn: pinnedBinding(for: location)) { EmptyView() }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!location.isManaged)
                        Spacer()
                    }
                }
                .customizationID("individualToggle")

                TableColumn("Name") { location in
                    Text(location.displayName)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 160, ideal: 200)

                TableColumn("Root Path") { location in
                    Text(location.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 220, ideal: 320)

                TableColumn("Actions") { location in
                    HStack(spacing: 10) {
                        Button {
                            beginRename(location)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename Location")

                        Button {
                            browse(location.rootPath)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Browse Root")

                        Button(role: .destructive) {
                            locationToDelete = location
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete Location")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 110, ideal: 120, max: 140)
            }
            .frame(minHeight: 260)
            .background(TableViewAccessor(tableView: $locationsTableView, onResolve: applyHeaderTooltips))
        }
        .padding(containerPadding)
        .sheet(isPresented: $showingCustomNameSheet) {
            NameEditSheet(title: "Add Custom Location",
                          placeholder: "Location name",
                          name: $customLocationName,
                          validationError: $customNameError,
                          onSave: { name in
                              saveCustomLocation(named: name)
                          },
                          onCancel: {
                              showingCustomNameSheet = false
                          })
        }
        .sheet(item: $locationToRename) { location in
            NameEditSheet(title: "Rename Location",
                          placeholder: "Location name",
                          name: $renameLocationName,
                          validationError: $renameError,
                          onSave: { name in
                              rename(location, to: name)
                          },
                          onCancel: {
                              locationToRename = nil
                          })
        }
        .alert("Delete Location?", isPresented: Binding(
            get: { locationToDelete != nil },
            set: { if !$0 { locationToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let location = locationToDelete {
                    remove(location)
                }
                locationToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                locationToDelete = nil
            }
        } message: {
            if let location = locationToDelete {
                Text("Delete \"\(location.displayName)\"? This removes the sync location and its per-skill selections.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Skills Sync Locations")
                .font(headerFont)
            Spacer()

            Menu {
                ForEach(availableTemplates) { template in
                    Button(template.displayName) {
                        addStandardLocation(template)
                    }
                }
            } label: {
                Label("Add Standard Location", systemImage: "plus")
            }
            .disabled(availableTemplates.isEmpty)

            Button {
                addCustomLocation()
            } label: {
                Label("Add Custom Location…", systemImage: "folder.badge.plus")
            }
        }
    }

    private var verticalSpacing: CGFloat {
        displayStyle == .standalone ? 12 : 8
    }

    private var containerPadding: CGFloat {
        displayStyle == .standalone ? 16 : 0
    }

    private var headerFont: Font {
        displayStyle == .standalone ? .title3.bold() : .headline
    }

    private var sortedLocations: [SkillSyncLocation] {
        locations.sorted { lhs, rhs in
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

#if os(macOS)
    private func applyHeaderTooltips(_ tableView: NSTableView) {
        if tableView.rowSizeStyle != .small {
            tableView.rowSizeStyle = .small
        }
        let currentSpacing = tableView.intercellSpacing
        let targetSpacing = NSSize(width: currentSpacing.width, height: 2)
        if currentSpacing.height != targetSpacing.height {
            tableView.intercellSpacing = targetSpacing
        }

        if let column = tableView.tableColumns.first(where: {
            $0.identifier.rawValue == "individualToggle" || $0.title == "Individual toggle"
        }) {
            sizeColumnToHeader(column, extraPadding: 8)
        }

        tableView.headerView?.needsDisplay = true
    }

    private func sizeColumnToHeader(_ column: NSTableColumn, extraPadding: CGFloat) {
        let headerWidth = column.headerCell.cellSize.width + extraPadding
        let targetWidth = ceil(headerWidth)
        guard column.width != targetWidth || column.minWidth != targetWidth || column.maxWidth != targetWidth else { return }
        column.minWidth = targetWidth
        column.maxWidth = targetWidth
        column.width = targetWidth
    }
#endif

    private var availableTemplates: [SkillSyncLocationTemplate] {
        let configuredKeys = Set(locations.compactMap { $0.templateKey ?? $0.locationId })
        return SkillSyncLocationTemplates.all.filter { !configuredKeys.contains($0.key) }
    }

    private func managedBinding(for location: SkillSyncLocation) -> Binding<Bool> {
        Binding(get: { location.isManaged },
                set: { newValue in
                    pinError = nil
                    addError = nil
                    location.setManaged(newValue)
                    if !newValue, location.isPinned {
                        location.setPinRank(nil)
                        normalizePinRanks()
                    }
                    saveContext()
                })
    }

    private func pinnedBinding(for location: SkillSyncLocation) -> Binding<Bool> {
        Binding(get: { location.isPinned },
                set: { newValue in
                    pinError = nil
                    addError = nil
                    if newValue {
                        let pinned = locations.filter { $0.isPinned }
                        if pinned.count >= 3 {
                            pinError = "You can enable up to 3 individual toggles."
                            return
                        }
                        let nextRank = (pinned.compactMap(\.pinRank).max() ?? -1) + 1
                        location.setPinRank(nextRank)
                    } else {
                        location.setPinRank(nil)
                        normalizePinRanks()
                    }
                    saveContext()
                })
    }

    private func normalizePinRanks() {
        let ordered = locations
            .filter { $0.pinRank != nil }
            .sorted { ($0.pinRank ?? 0) < ($1.pinRank ?? 0) }
        for (index, location) in ordered.enumerated() {
            if location.pinRank != index {
                location.setPinRank(index)
            }
        }
    }

    private func addStandardLocation(_ template: SkillSyncLocationTemplate) {
        let rootPath = template.expandedRootURL().path
        guard validateRootPath(rootPath) else { return }

        let location = SkillSyncLocation(locationId: template.key,
                                         displayName: template.displayName,
                                         rootPath: rootPath,
                                         disabledRootPath: template.expandedDisabledURL().path,
                                         isManaged: false,
                                         pinRank: nil,
                                         templateKey: template.key,
                                         kind: .builtIn)
        modelContext.insert(location)
        saveContext()
    }

    private func addCustomLocation() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = "Choose Skills Folder"
        panel.message = "Select the root folder where the client reads skills."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let rootPath = url.standardizedFileURL.path
        guard validateRootPath(rootPath) else { return }

        customLocationRoot = url
        customLocationName = url.lastPathComponent
        customNameError = nil
        showingCustomNameSheet = true
        #endif
    }

    private func beginRename(_ location: SkillSyncLocation) {
        renameLocationName = location.displayName
        renameError = nil
        locationToRename = location
    }

    private func rename(_ location: SkillSyncLocation, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameError = "Name cannot be empty."
            return
        }

        renameError = nil
        location.updateDisplayName(trimmed)
        saveContext()
        locationToRename = nil
    }

    private func saveCustomLocation(named name: String) {
        guard let rootURL = customLocationRoot else {
            showingCustomNameSheet = false
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customNameError = "Name cannot be empty."
            return
        }

        let rootPath = rootURL.standardizedFileURL.path
        guard validateRootPath(rootPath) else {
            customNameError = addError
            return
        }

        let disabledPath = SkillSyncLocationTemplates
            .defaultDisabledPath(for: rootURL)
            .standardizedFileURL
            .path

        let location = SkillSyncLocation(locationId: UUID().uuidString,
                                         displayName: trimmed,
                                         rootPath: rootPath,
                                         disabledRootPath: disabledPath,
                                         isManaged: false,
                                         pinRank: nil,
                                         templateKey: nil,
                                         kind: .custom)
        modelContext.insert(location)
        saveContext()
        showingCustomNameSheet = false
    }

    private func validateRootPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if locations.contains(where: {
            URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path == standardized
        }) {
            addError = "That root path is already configured."
            return false
        }
        addError = nil
        return true
    }

    private func remove(_ location: SkillSyncLocation) {
        modelContext.delete(location)
        saveContext()
    }

    private func saveContext() {
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            addError = "Failed to save locations: \(error.localizedDescription)"
        }
    }

    private func browse(_ rawPath: String) {
        #if os(macOS)
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
