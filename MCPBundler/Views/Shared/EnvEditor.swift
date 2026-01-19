//
//  EnvEditor.swift
//  MCP Bundler
//
//  Reusable editor for environment variables at project or server scope.
//

import SwiftUI
import Foundation

struct EnvEditor: View {
    var envVars: [EnvVar]
    var onDelete: ((EnvVar) -> Void)? = nil
    var showValues: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            ForEach(envVars) { env in
                EnvEditorRow(env: env, showPlainByDefault: showValues, onDelete: onDelete)
            }
        }
    }
}

// MARK: - Shared date/time formatting helpers

extension Date {
    /// Abbreviated date + short time. Omits year when it's the current year.
    func mcpShortDateTime() -> String {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let year = calendar.component(.year, from: self)

        var fmt = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day(.twoDigits)
            .hour(.defaultDigits(amPM: .abbreviated))
            .minute(.twoDigits)
        if year != thisYear {
            fmt = fmt.year(.defaultDigits)
        }
        return self.formatted(fmt)
    }

    /// Abbreviated date only. Omits year when it's the current year.
    func mcpShortDate() -> String {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let year = calendar.component(.year, from: self)

        var fmt = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day(.twoDigits)
        if year != thisYear {
            fmt = fmt.year(.defaultDigits)
        }
        return self.formatted(fmt)
    }
}

private struct EnvEditorRow: View {
    var env: EnvVar
    var showPlainByDefault: Bool
    var onDelete: ((EnvVar) -> Void)?
    @State private var showValue: Bool = true
    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KEY")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Enter variable name", text: Binding(
                    get: { env.key },
                    set: { env.key = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            .frame(minWidth: 180)

            VStack(alignment: .leading, spacing: 4) {
                Text("VALUE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("=")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)

                    if showValue {
                        TextField("Enter value", text: Binding(
                            get: { env.plainValue ?? "" },
                            set: {
                                env.valueSource = .plain
                                env.plainValue = $0
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Enter value", text: .constant(String(repeating: "*", count: max((env.plainValue ?? "").count, 1))))
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

                    if let onDelete {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete variable")
                        .confirmationDialog(
                            "Delete Environment Variable",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) {
                                onDelete(env)
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Are you sure you want to delete the environment variable '\(env.key)'? This action cannot be undone.")
                        }
                    }
                }
            }
        }
        .onAppear {
            if env.valueSource != .plain {
                env.valueSource = .plain
            }
            let isNewEntry = (env.plainValue ?? "").isEmpty
            showValue = isNewEntry || showPlainByDefault
        }
    }
}

private struct LabeledInput: View {
    var title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
