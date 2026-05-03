import PencilKit

@MainActor
final class SharedToolPicker {
    static let shared = SharedToolPicker()
    let picker = PKToolPicker()
    private init() {}
}
