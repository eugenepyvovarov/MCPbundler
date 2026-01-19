//
//  ToastHost.swift
//  MCP Bundler
//
//  Overlay presenter for toast messages dispatched through ToastCenter.
//

import SwiftUI

struct ToastHost: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(spacing: 10) {
            ForEach(center.queue) { message in
                ToastBubble(message: message) {
                    center.remove(message.id)
                }
            }
        }
        .frame(maxWidth: 320)
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: center.queue)
    }
}

private struct ToastBubble: View {
    let message: ToastMessage
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.systemImage ?? message.style.iconName)
                .foregroundStyle(.white)
                .imageScale(.medium)
            Text(message.text)
                .foregroundStyle(.white)
                .font(.callout)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                withAnimation {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.style.tint.gradient)
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(isHovering ? 0.25 : 0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 14, x: 0, y: 8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
