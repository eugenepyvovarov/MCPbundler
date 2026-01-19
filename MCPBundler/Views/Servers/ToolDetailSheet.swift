//
//  ToolDetailSheet.swift
//  MCP Bundler
//
//  Sheet for displaying detailed information about a tool.
//

import SwiftUI
import MCP

struct ToolDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: Tool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tool.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let title = tool.annotations.title, !title.isEmpty {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    if let description = tool.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.headline)
                            Text(description)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Input Schema")
                            .font(.headline)
                        Text(formatJSON(tool.inputSchema))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    if !tool.annotations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Annotations")
                                .font(.headline)

                            if let title = tool.annotations.title, !title.isEmpty {
                                detailRow("Title", title)
                            }

                            if let destructiveHint = tool.annotations.destructiveHint {
                                detailRow("Destructive", destructiveHint ? "Yes" : "No", color: destructiveHint ? .red : nil)
                            }

                            if let readOnlyHint = tool.annotations.readOnlyHint {
                                detailRow("Read Only", readOnlyHint ? "Yes" : "No")
                            }

                            if let idempotentHint = tool.annotations.idempotentHint {
                                detailRow("Idempotent", idempotentHint ? "Yes" : "No")
                            }

                            if let openWorldHint = tool.annotations.openWorldHint {
                                detailRow("Open World", openWorldHint ? "Yes" : "No")
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func detailRow(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(color ?? .primary)
        }
    }

    private func formatJSON(_ value: Value) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: prettyData, as: UTF8.self)
        } catch {
            return String(describing: value)
        }
    }
}

#Preview {
    ToolDetailSheet(tool: Tool(
        name: "example_tool",
        description: "This is an example tool for demonstration purposes.",
        inputSchema: .object([
            "query": .string(""),
            "limit": .int(0)
        ]),
        annotations: .init(
            title: "Example Tool",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: true
        )
    ))
}
