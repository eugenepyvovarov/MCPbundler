//
//  ServerFormComponents.swift
//  MCP Bundler
//
//  Shared subviews for server configuration forms.
//

import SwiftUI

enum ServerEditorTab: String, CaseIterable, Identifiable {
    case basics
    case auth
    case tools

    var id: String { rawValue }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            HStack {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? .primary : .secondary)
                configuration.label
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct HeaderEditor: View {
    var headers: [HeaderBinding]
    var onDelete: ((HeaderBinding) -> Void)? = nil
    var showValues: Bool = true
    var allowsOAuthSource: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            ForEach(headers) { header in
                HeaderEditorRow(header: header,
                                 showPlainByDefault: showValues,
                                 allowsOAuthSource: allowsOAuthSource,
                                 onDelete: onDelete)
            }
        }
    }
}

private struct HeaderEditorRow: View {
    var header: HeaderBinding
    var showPlainByDefault: Bool
    var allowsOAuthSource: Bool
    var onDelete: ((HeaderBinding) -> Void)?

    @State private var showValue: Bool = true
    @State private var showDeleteConfirmation: Bool = false

    private var resolvedSource: SecretSource {
        if allowsOAuthSource && header.valueSource == .oauthAccessToken {
            return .oauthAccessToken
        }
        return .plain
    }

    private var sourceLabel: String {
        switch resolvedSource {
        case .plain:
            return "Plain Text"
        case .oauthAccessToken:
            return "OAuth Token"
        default:
            return "Plain Text"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HEADER")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Enter header name", text: Binding(
                    get: { header.header },
                    set: { header.header = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("VALUE")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if resolvedSource == .plain {
                    HStack(spacing: 6) {
                        Text("=")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        if showValue {
                            TextField("Enter value", text: Binding(
                                get: { header.plainValue ?? "" },
                                set: { header.plainValue = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(
                                "Enter value",
                                text: .constant(String(repeating: "*", count: max((header.plainValue ?? "").count, 1)))
                            )
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showValue.toggle()
                            }
                        } label: {
                            Image(systemName: showValue ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(showValue ? "Hide value" : "Show value")
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("=")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Managed automatically by OAuth")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            if allowsOAuthSource {
                Menu {
                    if resolvedSource != .plain {
                        Button("Use Plain Text") {
                            header.valueSource = .plain
                            header.plainValue = header.plainValue ?? ""
                            showValue = showPlainByDefault
                        }
                    }
                    if resolvedSource != .oauthAccessToken {
                        Button("Use OAuth Token") {
                            header.valueSource = .oauthAccessToken
                            header.plainValue = nil
                            header.keychainRef = nil
                            if header.header.isEmpty {
                                header.header = "Authorization"
                            }
                            showValue = false
                        }
                    }
                    if let onDelete {
                        Divider()
                        Button("Delete Header", role: .destructive) {
                            showDeleteConfirmation = false
                            onDelete(header)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            } else if let onDelete {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete header")
                .confirmationDialog(
                    "Delete Header",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) { onDelete(header) }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Delete header '\(header.header)'?")
                }
            }
        }
        .onAppear {
            if !allowsOAuthSource && header.valueSource != .plain {
                header.valueSource = .plain
            }
            if allowsOAuthSource && header.valueSource != .plain && header.valueSource != .oauthAccessToken {
                header.valueSource = .plain
            }
            showValue = resolvedSource == .plain ? (showPlainByDefault || (header.plainValue ?? "").isEmpty) : false
        }
    }
}




struct TermsEditor: View {
    @State private var newTerm: String = ""
    var label: String
    var terms: Binding<[String]>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                TextField("Add term", text: $newTerm)
                    .onSubmit(add)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(Array(terms.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack {
                    TextField("term", text: Binding(
                        get: { terms.wrappedValue[index] },
                        set: { terms.wrappedValue[index] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        terms.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func add() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        terms.wrappedValue.append(trimmed)
        newTerm = ""
    }
}

struct LocalStdioConfigurationForm: View {
    enum Layout {
        case stacked
        case labeled(width: CGFloat)
    }

    var layout: Layout = .stacked
    var execLabel: LocalizedStringKey = "Executable"
    var argsLabel: LocalizedStringKey = "Arguments"
    var envLabel: LocalizedStringKey = "Env Vars"
    var execPlaceholder: LocalizedStringKey = "/path/to/binary"
    var argsPlaceholder: LocalizedStringKey = "--flag value"
    var addEnvButtonLabel: LocalizedStringKey = "Add Variable"
    var showEnvValues: Bool = true

    @Binding var execPath: String
    @Binding var argumentsText: String
    var envVars: [EnvVar]
    var onAddEnvVar: () -> Void
    var onDeleteEnvVar: (EnvVar) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField(label: execLabel) {
                TextField(execPlaceholder, text: $execPath)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField(label: argsLabel) {
                TextField(argsPlaceholder, text: $argumentsText)
                    .textFieldStyle(.roundedBorder)
            }

            envHeader

            EnvEditor(envVars: envVars, onDelete: onDeleteEnvVar, showValues: showEnvValues)
        }
    }

    @ViewBuilder
    private var envHeader: some View {
        switch layout {
        case .stacked:
            HStack {
                Text(envLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAddEnvVar) {
                    Label(addEnvButtonLabel, systemImage: "plus")
                }
            }
        case .labeled(let width):
            HStack {
                Text(envLabel)
                    .frame(width: width, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Button(action: onAddEnvVar) {
                    Label(addEnvButtonLabel, systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(label: LocalizedStringKey,
                                             @ViewBuilder content: () -> Content) -> some View {
        switch layout {
        case .stacked:
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                content()
            }
        case .labeled(let width):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .frame(width: width, alignment: .trailing)
                    .foregroundStyle(.secondary)
                content()
            }
        }
    }
}
