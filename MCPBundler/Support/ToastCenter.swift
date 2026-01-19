//
//  ToastCenter.swift
//  MCP Bundler
//
//  Lightweight observable hub for transient, app-wide toast messages.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var queue: [ToastMessage] = []

    func push(_ message: ToastMessage) {
        queue.append(message)
        scheduleRemoval(for: message)
        trimIfNeeded()
    }

    func push(text: String,
              style: ToastStyle,
              systemImage: String? = nil,
              duration: TimeInterval = 3.5) {
        let message = ToastMessage(text: text,
                                   style: style,
                                   systemImage: systemImage,
                                   duration: duration)
        push(message)
    }

    func remove(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
        }
    }

    private func scheduleRemoval(for message: ToastMessage) {
        let id = message.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(message.duration * 1_000_000_000))
            await self?.remove(id)
        }
    }

    private func trimIfNeeded(maximumCount: Int = 3) {
        if queue.count > maximumCount {
            queue.removeFirst(queue.count - maximumCount)
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let text: String
    let style: ToastStyle
    let systemImage: String?
    let duration: TimeInterval
}

enum ToastStyle: String {
    case success
    case warning
    case info

    var tint: Color {
        switch self {
        case .success: return .green
        case .warning: return .orange
        case .info: return .accentColor
        }
    }

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}
