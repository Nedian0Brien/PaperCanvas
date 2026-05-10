import SwiftUI

struct PageIndicator: View {
    let currentIndex: Int
    let totalPages: Int
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            Text("\(currentIndex + 1) / \(max(totalPages, 1))")
                .font(AppType.monoCaption)
                .foregroundStyle(Color.Ink.secondary)
                .monospacedDigit()
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityLabel("페이지 \(currentIndex + 1) / \(max(totalPages, 1))")
    }
}
