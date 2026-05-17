import SwiftUI

enum Motion {
    static let indirect: Animation = .spring(duration: 0.38, bounce: 0.22)
    static let indirectFast: Animation = .easeInOut(duration: 0.18)
    static let chromeFade: Animation = .easeInOut(duration: 0.16)
    static let morphContent: Animation = .smooth(duration: 0.2, extraBounce: 0.0)

    static let chromeFadeDuration: Double = 0.16
    static let dimDuringStrokeOpacity: Double = 0.6
    static let strokeIdleSeconds: Double = 2.5
    static let saveDebounceSeconds: Double = 0.8
}
