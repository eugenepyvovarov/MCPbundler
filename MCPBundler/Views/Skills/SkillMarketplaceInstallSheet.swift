//
//  SkillMarketplaceInstallSheet.swift
//  MCP Bundler
//
//  UI for browsing and installing skills from marketplace sources.
//

import SwiftUI
import SwiftData
import AppKit

struct SkillMarketplaceInstallSheet: View {
    private static let allCategoriesLabel = "All"
    private static let uncategorizedLabel = "Uncategorized"

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var sources: [SkillMarketplaceSource]
    @Query private var skills: [SkillRecord]

    @State private var selectedSourceId: String?
    @State private var selectedCategory = Self.allCategoriesLabel
    @State private var listing: SkillMarketplaceListing?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var installingPluginName: String?
    @State private var filterTokens: [String] = []
    @State private var filterDraft = ""
    @State private var suggestionIndex = 0
    @State private var keyMonitor: Any?
    @FocusState private var filterFieldFocused: Bool

    private let service: SkillMarketplaceService
    private let onInstalled: () async -> Void

    init(onInstalled: @escaping () async -> Void,
         service: SkillMarketplaceService = SkillMarketplaceService()) {
        self.onInstalled = onInstalled
        self.service = service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if sources.isEmpty {
                Text("No marketplace sources configured. Add one in Project Settings.")
                    .foregroundStyle(.secondary)
            } else if sortedSources.isEmpty {
                Text("No marketplaces with SKILL.md skills available.")
                    .foregroundStyle(.secondary)
            } else {
                pickerRow
                filterRow

                if isLoading {
                    ProgressView("Loading marketplace...")
                        .progressViewStyle(.linear)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if let listing {
                    let plugins = filteredPlugins(for: listing)
                    Text("Total: \(plugins.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    pluginList(plugins, listing: listing)
                } else if !isLoading {
                    Text("Select a marketplace source to browse skills.")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(minWidth: 744, minHeight: 520, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            selectDefaultSourceIfNeeded()
        }
        .onAppear {
            installKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: sources) { _, _ in
            selectDefaultSourceIfNeeded()
        }
        .onChange(of: selectedSourceId) { _, newValue in
            resetTokenFilters()
            guard let newValue,
                  let source = sources.first(where: { $0.sourceId == newValue }) else { return }
            Task {
                await loadMarketplace(for: source)
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            normalizeSuggestionIndex()
        }
        .onChange(of: filterDraft) { _, _ in
            normalizeSuggestionIndex()
        }
        .onChange(of: filterTokens) { _, _ in
            normalizeSuggestionIndex()
        }
    }

    private var header: some View {
        HStack {
            Text("Skills Marketplace")
                .font(.title3.bold())
        }
    }

    private var pickerRow: some View {
        HStack(spacing: 20) {
            sourcePicker
            categoryPicker
            Spacer()
        }
    }

    private var filterRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Filter")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Add tag, author, or keyword", text: $filterDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFieldFocused)
                    .onSubmit {
                        commitTokenDraft()
                    }
                    .onChange(of: filterDraft) { _, newValue in
                        consumeTokenDraftIfNeeded(newValue)
                    }
                if shouldShowSuggestions {
                    suggestionList
                }
                if !filterTokens.isEmpty {
                    tokenPills
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer()
        }
        .disabled(listing == nil)
    }

    private var sourcePicker: some View {
        HStack(spacing: 12) {
            Text("Source")
                .font(.subheadline.weight(.semibold))
            Picker("", selection: $selectedSourceId) {
                Text("Select a source")
                    .foregroundStyle(.secondary)
                    .tag(String?.none)
                ForEach(sortedSources) { source in
                    Text(source.displayName)
                        .tag(source.sourceId as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var categoryPicker: some View {
        HStack(spacing: 12) {
            Text("Category")
                .font(.subheadline.weight(.semibold))
            Picker("", selection: $selectedCategory) {
                Text(Self.allCategoriesLabel)
                    .tag(Self.allCategoriesLabel)
                ForEach(availableCategories, id: \.self) { category in
                    Text(category)
                        .tag(category)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(listing == nil)
        }
    }

    private var tokenPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filterTokens, id: \.self) { token in
                    filterTokenPill(token)
                }
            }
        }
    }

    private var suggestionList: some View {
        let suggestions = currentSuggestions
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button {
                        acceptSuggestion(suggestion)
                    } label: {
                        HStack {
                            Text(suggestion.label)
                                .font(.caption)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(index == suggestionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private func pluginList(_ plugins: [SkillMarketplacePlugin], listing: SkillMarketplaceListing) -> some View {
        List {
            ForEach(plugins) { plugin in
                let installed = installedSlugs.contains(plugin.name.lowercased())
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(displayName(for: plugin.name))
                            .font(.headline)
                        Spacer()
                        pluginAction(for: plugin, listing: listing, installed: installed)
                    }
                    Text(plugin.description ?? "No description provided.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    metaRow(for: plugin)
                    tagPills(for: plugin)
                }
                .padding(.vertical, 6)
                .listRowBackground(installed ? Color.green.opacity(0.15) : Color.clear)
            }
        }
    }

    @ViewBuilder
    private func pluginAction(for plugin: SkillMarketplacePlugin,
                              listing: SkillMarketplaceListing,
                              installed: Bool) -> some View {
        if installed {
            Button("Installed") {}
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(true)
        } else if installingPluginName == plugin.name {
            ProgressView()
        } else {
            Button("Install") {
                install(plugin, listing: listing)
            }
            .disabled(isLoading || installingPluginName != nil)
        }
    }

    private func filterTokenPill(_ token: String) -> some View {
        Button {
            removeFilterToken(token)
        } label: {
            HStack(spacing: 4) {
                Text(token)
                    .font(.caption)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    @ViewBuilder
    private func metaRow(for plugin: SkillMarketplacePlugin) -> some View {
        let author = authorName(for: plugin)
        let category = displayCategory(for: plugin)
        if author != nil || category != nil {
            HStack(spacing: 8) {
                if let author {
                    Button {
                        addFilterToken(author)
                    } label: {
                        pillLabel("Author: \(author)")
                    }
                    .buttonStyle(.plain)
                }
                if let category {
                    Button {
                        selectedCategory = category
                    } label: {
                        pillLabel("Category: \(category)")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func tagPills(for plugin: SkillMarketplacePlugin) -> some View {
        let tags = normalizedTags(for: plugin)
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            addFilterToken(tag)
                        } label: {
                            pillLabel("Tag:\(tag)")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var sortedSources: [SkillMarketplaceSource] {
        let filtered = sources.filter { source in
            if let cachedNames = source.cachedSkillNames() {
                return !cachedNames.isEmpty
            }
            return true
        }
        return SkillMarketplaceSourceDefaults.sortSources(filtered)
    }

    private var availableCategories: [String] {
        guard let listing else { return [] }
        let categories = Set(listing.document.plugins.map { categoryLabel(for: $0) })
        return categories.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private var installedSlugs: Set<String> {
        Set(skills.map { $0.slug.lowercased() })
    }

    private var normalizedFilterTokens: [String] {
        filterTokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    private struct AuthorCount: Hashable {
        var name: String
        var count: Int
    }

    private var currentSuggestions: [FilterSuggestion] {
        let query = filterDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, let listing else { return [] }
        let existing = Set(normalizedFilterTokens)
        let basePlugins = filteredPlugins(for: listing)
        let tagSuggestions = tagCounts(in: basePlugins)
            .sorted { lhs, rhs in
                lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .compactMap { (tag, count) -> FilterSuggestion? in
                guard tag.contains(query), !existing.contains(tag) else { return nil }
                return FilterSuggestion(kind: .tag, value: tag, count: count)
            }
        let authorSuggestions = authorCounts(in: basePlugins)
            .sorted { lhs, rhs in
                lhs.value.name.localizedCaseInsensitiveCompare(rhs.value.name) == .orderedAscending
            }
            .compactMap { (key, author) -> FilterSuggestion? in
                guard author.name.lowercased().contains(query), !existing.contains(key) else { return nil }
                return FilterSuggestion(kind: .author, value: author.name, count: author.count)
            }
        let combined = (authorSuggestions + tagSuggestions)
            .sorted { lhs, rhs in
                lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        return Array(combined.prefix(8))
    }

    private var shouldShowSuggestions: Bool {
        filterFieldFocused && !currentSuggestions.isEmpty
    }

    private func displayName(for raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return spaced }
        return String(first).uppercased() + spaced.dropFirst()
    }

    private func categoryLabel(for plugin: SkillMarketplacePlugin) -> String {
        let trimmed = plugin.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return Self.uncategorizedLabel }
        let spaced = trimmed.replacingOccurrences(of: "-", with: " ")
        let normalized = spaced.lowercased().capitalized
        return normalized.isEmpty ? Self.uncategorizedLabel : normalized
    }

    private func authorName(for plugin: SkillMarketplacePlugin) -> String? {
        let trimmed = plugin.author?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func displayCategory(for plugin: SkillMarketplacePlugin) -> String? {
        let trimmed = plugin.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let spaced = trimmed.replacingOccurrences(of: "-", with: " ")
        let normalized = spaced.lowercased().capitalized
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedTags(for plugin: SkillMarketplacePlugin) -> [String] {
        guard let keywords = plugin.keywords else { return [] }
        var tags: [String] = []
        var seen = Set<String>()
        for raw in keywords {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                tags.append(trimmed)
            }
        }
        return tags
    }

    private func tagCounts(in plugins: [SkillMarketplacePlugin]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for plugin in plugins {
            let tags = Set(normalizedTags(for: plugin))
            for tag in tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
    }

    private func authorCounts(in plugins: [SkillMarketplacePlugin]) -> [String: AuthorCount] {
        var counts: [String: AuthorCount] = [:]
        for plugin in plugins {
            guard let author = authorName(for: plugin) else { continue }
            let key = author.lowercased()
            if var entry = counts[key] {
                entry.count += 1
                counts[key] = entry
            } else {
                counts[key] = AuthorCount(name: author, count: 1)
            }
        }
        return counts
    }

    private func pluginSearchText(for plugin: SkillMarketplacePlugin) -> String {
        var parts: [String] = [plugin.name]
        if let description = plugin.description {
            parts.append(description)
        }
        if let author = authorName(for: plugin) {
            parts.append(author)
        }
        parts.append(contentsOf: normalizedTags(for: plugin))
        return parts.joined(separator: " ").lowercased()
    }

    private func filteredPlugins(for listing: SkillMarketplaceListing) -> [SkillMarketplacePlugin] {
        var plugins = listing.document.plugins
        if selectedCategory != Self.allCategoriesLabel {
            plugins = plugins.filter { categoryLabel(for: $0) == selectedCategory }
        }
        let tokens = normalizedFilterTokens
        guard !tokens.isEmpty else { return plugins }
        return plugins.filter { plugin in
            let searchText = pluginSearchText(for: plugin)
            return tokens.allSatisfy { searchText.contains($0) }
        }
    }

    private func addFilterToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = trimmed.lowercased()
        guard !filterTokens.contains(where: { $0.lowercased() == normalized }) else { return }
        filterTokens.append(trimmed)
    }

    private func removeFilterToken(_ token: String) {
        let normalized = token.lowercased()
        filterTokens.removeAll { $0.lowercased() == normalized }
    }

    private func commitTokenDraft() {
        addFilterToken(filterDraft)
        filterDraft = ""
        suggestionIndex = 0
    }

    private func consumeTokenDraftIfNeeded(_ value: String) {
        guard value.contains(",") else { return }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        for part in parts.dropLast() {
            addFilterToken(String(part))
        }
        let remainder = parts.last.map(String.init) ?? ""
        filterDraft = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetTokenFilters() {
        filterTokens = []
        filterDraft = ""
        suggestionIndex = 0
    }

    private func normalizeSuggestionIndex() {
        let suggestions = currentSuggestions
        if suggestions.isEmpty {
            suggestionIndex = 0
            return
        }
        if suggestionIndex >= suggestions.count {
            suggestionIndex = 0
        }
    }

    private func acceptSuggestion(_ suggestion: FilterSuggestion) {
        addFilterToken(suggestion.value)
        filterDraft = ""
        suggestionIndex = 0
    }

    private func acceptSelectedSuggestion() {
        let suggestions = currentSuggestions
        guard !suggestions.isEmpty else { return }
        let index = min(max(suggestionIndex, 0), suggestions.count - 1)
        acceptSuggestion(suggestions[index])
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard filterFieldFocused, shouldShowSuggestions else { return event }
        switch event.keyCode {
        case 125: // down arrow
            suggestionIndex = min(suggestionIndex + 1, currentSuggestions.count - 1)
            return nil
        case 126: // up arrow
            suggestionIndex = max(suggestionIndex - 1, 0)
            return nil
        case 36: // return
            acceptSelectedSuggestion()
            return nil
        case 53: // escape
            filterDraft = ""
            suggestionIndex = 0
            return nil
        default:
            return event
        }
    }

    private func reconcileCategorySelection(for listing: SkillMarketplaceListing?) {
        guard let listing else {
            selectedCategory = Self.allCategoriesLabel
            return
        }
        let categories = Set(listing.document.plugins.map { categoryLabel(for: $0) })
        guard selectedCategory != Self.allCategoriesLabel else { return }
        if !categories.contains(selectedCategory) {
            selectedCategory = Self.allCategoriesLabel
        }
    }

    private func selectDefaultSourceIfNeeded() {
        if sources.isEmpty {
            selectedSourceId = nil
            listing = nil
            selectedCategory = Self.allCategoriesLabel
            resetTokenFilters()
            return
        }

        if let selectedSourceId,
           sources.contains(where: { $0.sourceId == selectedSourceId }) {
            return
        }

        selectedSourceId = nil
        listing = nil
        resetTokenFilters()

        if let first = sortedSources.first {
            selectedSourceId = first.sourceId
        }
    }

    private func loadMarketplace(for source: SkillMarketplaceSource) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            listing = nil
            reconcileCategorySelection(for: nil)
        }

        let snapshot = await MainActor.run {
            (
                owner: source.owner,
                repo: source.repo,
                cachedManifestSHA: source.cachedManifestSHA,
                cachedMarketplaceJSON: source.cachedMarketplaceJSON,
                cachedSkillNames: source.cachedSkillNames(),
                cachedDefaultBranch: source.cachedDefaultBranch
            )
        }

        do {
            let result = try await service.fetchMarketplaceSkills(owner: snapshot.owner,
                                                                  repo: snapshot.repo,
                                                                  cachedManifestSHA: snapshot.cachedManifestSHA,
                                                                  cachedMarketplaceJSON: snapshot.cachedMarketplaceJSON,
                                                                  cachedSkillNames: snapshot.cachedSkillNames,
                                                                  cachedDefaultBranch: snapshot.cachedDefaultBranch)
            await MainActor.run {
                listing = result.listing
                reconcileCategorySelection(for: result.listing)
                if let warning = result.warningMessage {
                    errorMessage = warning
                }
                if let update = result.cacheUpdate {
                    source.updateMarketplaceCache(manifestSHA: update.manifestSHA,
                                                  defaultBranch: update.defaultBranch,
                                                  manifestJSON: update.manifestJSON,
                                                  skillNames: update.skillNames)
                    do {
                        if modelContext.hasChanges {
                            try modelContext.save()
                        }
                    } catch {
                        errorMessage = "Failed to save marketplace cache: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isLoading = false
        }
    }

    private func install(_ plugin: SkillMarketplacePlugin, listing: SkillMarketplaceListing) {
        guard installingPluginName == nil else { return }
        installingPluginName = plugin.name
        errorMessage = nil

        Task {
            do {
                _ = try await service.installPlugin(plugin,
                                                   from: listing,
                                                   existingSlugs: installedSlugs)
                await onInstalled()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                installingPluginName = nil
            }
        }
    }
}

private struct FilterSuggestion: Identifiable, Hashable {
    enum Kind: String {
        case tag
        case author
    }

    let kind: Kind
    let value: String
    let count: Int

    var id: String {
        "\(kind.rawValue):\(value.lowercased())"
    }

    var label: String {
        switch kind {
        case .tag:
            return "Tag:\(value) (\(count))"
        case .author:
            return "Author:\(value) (\(count))"
        }
    }
}
