import CoreGraphics

enum TopBarMetrics {
    static let barHeight: CGFloat = 56
    static let buttonSize: CGFloat = 40
    static let interButtonSpacing: CGFloat = 6
    static let zoneSpacing: CGFloat = 12
    static let outerHorizontalPadding: CGFloat = 12
    static let outerTopPadding: CGFloat = 8
    static let outerBottomPadding: CGFloat = 6

    static let titleMaxWidthFull: CGFloat = 320
    static let titleMaxWidthMid: CGFloat = 240
    static let titleMaxWidthCompact: CGFloat = 160
    static let titleMinHeight: CGFloat = 40
}

enum TopBarDensity {
    case full
    case mid
    case condensed
    case compact
    case minimal

    static func density(forAvailableWidth width: CGFloat) -> TopBarDensity {
        if width >= 1100 { return .full }
        if width >= 900 { return .mid }
        if width >= 720 { return .condensed }
        if width >= 600 { return .compact }
        return .minimal
    }

    var titleMaxWidth: CGFloat? {
        switch self {
        case .full: return TopBarMetrics.titleMaxWidthFull
        case .mid: return TopBarMetrics.titleMaxWidthMid
        case .condensed: return TopBarMetrics.titleMaxWidthCompact
        case .compact, .minimal: return nil
        }
    }

    var showsTitle: Bool {
        switch self {
        case .full, .mid, .condensed: return true
        case .compact, .minimal: return false
        }
    }

    var widthSlotCount: Int {
        switch self {
        case .full, .mid: return 3
        case .condensed: return 2
        case .compact: return 1
        case .minimal: return 1
        }
    }

    var colorSlotCount: Int {
        switch self {
        case .full, .mid, .condensed: return 3
        case .compact: return 2
        case .minimal: return 1
        }
    }

    var showsRightZoneContext: Bool {
        switch self {
        case .full, .mid, .condensed: return true
        case .compact, .minimal: return false
        }
    }

    var allowsHorizontalScroll: Bool {
        self == .minimal
    }
}
