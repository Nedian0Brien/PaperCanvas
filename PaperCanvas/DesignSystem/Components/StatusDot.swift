import SwiftUI

enum SaveStatus: Equatable {
    case idle
    case saving
    case saved(Date)
    case error(String)

    var tint: Color {
        switch self {
        case .idle: return Color.Status.idle
        case .saving: return Color.Status.saving
        case .saved: return Color.Status.saved
        case .error: return Color.Status.error
        }
    }

    var label: String {
        switch self {
        case .idle: return "변경 없음"
        case .saving: return "저장 중…"
        case .saved(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "저장됨 · " + formatter.localizedString(for: date, relativeTo: .now)
        case .error(let message): return "오류 · " + message
        }
    }
}

struct StatusDot: View {
    let status: SaveStatus
    var diameter: CGFloat = 10

    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(status.label)
    }
}
