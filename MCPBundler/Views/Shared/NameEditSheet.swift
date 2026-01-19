//
//  NameEditSheet.swift
//  MCP Bundler
//
//  Shared sheet used for simple create/rename flows.
//

import SwiftUI

struct NameEditSheet: View {
    let title: String
    let placeholder: String

    @Binding var name: String
    @Binding var validationError: String?

    var onSave: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
            if let validationError {
                Text(validationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") {
                    onSave(name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }
}

