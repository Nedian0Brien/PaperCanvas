import SwiftUI

struct ActiveCanvasBadge: View {
    enum Surface: String {
        case pdf = "PDF"
        case canvas = "Canvas"
    }

    let surface: Surface
    var isActive: Bool

    var body: some View {
        Text(surface.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .default))
            .tracking(0.4)
            .foregroundStyle(isActive ? Color.AccentTokens.primary : Color.Ink.tertiary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isActive ? Color.AccentTokens.tint : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    isActive ? Color.AccentTokens.primary.opacity(0.4) : Color.Rule.hairline,
                    lineWidth: 0.6
                )
            )
            .accessibilityLabel("\(surface.rawValue) 활성")
    }
}
