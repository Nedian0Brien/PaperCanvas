import SwiftUI

enum Motion {
    static let indirectFast: Animation = .easeInOut(duration: 0.18)
    static let chromeFade: Animation = .easeInOut(duration: 0.16)

    static let chromeFadeDuration: Double = 0.16
    static let dimDuringStrokeOpacity: Double = 0.6
    static let strokeIdleSeconds: Double = 2.5
    static let saveDebounceSeconds: Double = 0.8
}
