import SwiftUI

extension Color {
    enum Surface {
        static let paper = Color(.systemBackground)
        static let subtle = Color(.secondarySystemBackground)
        static let fill = Color(.tertiarySystemFill)
    }

    enum Ink {
        static let primary = Color(.label)
        static let secondary = Color(.secondaryLabel)
        static let tertiary = Color(.tertiaryLabel)
    }

    enum Rule {
        static let hairline = Color(.separator)
    }

    enum AccentTokens {
        static let primary = Color.accentColor
        static let tint = Color.accentColor.opacity(0.14)
    }

    enum Status {
        static let idle = Color(.tertiaryLabel)
        static let saving = Color.yellow
        static let saved = Color.green
        static let error = Color.red
    }
}
