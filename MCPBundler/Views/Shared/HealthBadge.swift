//
//  HealthBadge.swift
//  MCP Bundler
//
//  Displays a color-coded badge for server health status.
//

import SwiftUI

struct HealthBadge: View {
    var status: HealthStatus

    var body: some View {
        switch status {
        case .healthy:
            Label("Healthy", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .degraded:
            Label("Degraded", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .unhealthy:
            Label("Unhealthy", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unknown:
            Label("Unknown", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}
