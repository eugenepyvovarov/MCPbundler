//
//  MixedToggleSupport.swift
//  MCP Bundler
//

import SwiftUI

struct MixedToggleSource {
    let id: String
    let isOn: Binding<Bool>
}

@MainActor
final class ToggleBatchGate {
    private var isHandling = false

    func trigger(_ action: () -> Void) {
        guard !isHandling else { return }
        isHandling = true
        action()
        DispatchQueue.main.async { [weak self] in
            self?.isHandling = false
        }
    }
}
