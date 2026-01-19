//
//  CollapsibleCard.swift
//  MCP Bundler
//
//  Shared disclosure-style card used for advanced sections.
//

import SwiftUI

struct CollapsibleCard<Content: View>: View {
    @Binding var isExpanded: Bool
    let iconName: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    init(
        isExpanded: Binding<Bool>,
        iconName: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        _isExpanded = isExpanded
        self.iconName = iconName
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                header
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 20)
                    .opacity(0.25)

                content
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        )
        .shadow(color: Color.black.opacity(0.05), radius: 18, y: 10)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.26),
                                Color.accentColor.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .shadow(color: Color.accentColor.opacity(0.18), radius: 6, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.down")
                .font(.headline.weight(.semibold))
                .rotationEffect(isExpanded ? .degrees(180) : .zero)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }
}
