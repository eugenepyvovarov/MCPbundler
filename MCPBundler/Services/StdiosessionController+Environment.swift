import SwiftUI

private struct StdiosessionControllerKey: EnvironmentKey {
    static let defaultValue: StdiosessionController? = nil
}

extension EnvironmentValues {
    var stdiosessionController: StdiosessionController? {
        get { self[StdiosessionControllerKey.self] }
        set { self[StdiosessionControllerKey.self] = newValue }
    }
}
