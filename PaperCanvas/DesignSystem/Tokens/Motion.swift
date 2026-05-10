import SwiftUI

enum Motion {
    static let indirect: Animation = .spring(response: 0.4, dampingFraction: 0.85)
    static let indirectFast: Animation = .easeInOut(duration: 0.18)
    static let chromeFade: Animation = .easeInOut(duration: 0.16)

    static let chromeFadeDuration: Double = 0.16
    static let dimDuringStrokeOpacity: Double = 0.6
    static let strokeIdleSeconds: Double = 2.5
    static let saveDebounceSeconds: Double = 0.8
}
