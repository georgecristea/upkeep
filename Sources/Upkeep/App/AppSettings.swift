import Foundation

final class AppSettings: ObservableObject {
    /// Hours between automatic read-only checks. 0 = off.
    static let intervalChoices: [Int] = [0, 1, 6, 24]

    @Published private(set) var checkIntervalHours: Int
    @Published private(set) var notifyOnUpdates: Bool
    @Published private(set) var notifyOnCompletion: Bool

    private enum Key {
        static let checkIntervalHours = "checkIntervalHours"
        static let notifyOnUpdates = "notifyOnUpdates"
        static let notifyOnCompletion = "notifyOnCompletion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.checkIntervalHours: 6,
            Key.notifyOnUpdates: true,
            Key.notifyOnCompletion: true
        ])
        checkIntervalHours = defaults.integer(forKey: Key.checkIntervalHours)
        notifyOnUpdates = defaults.bool(forKey: Key.notifyOnUpdates)
        notifyOnCompletion = defaults.bool(forKey: Key.notifyOnCompletion)
    }

    func setCheckInterval(hours: Int) {
        checkIntervalHours = max(0, hours)
        defaults.set(checkIntervalHours, forKey: Key.checkIntervalHours)
    }

    func setNotifyOnUpdates(_ on: Bool) {
        notifyOnUpdates = on
        defaults.set(on, forKey: Key.notifyOnUpdates)
    }

    func setNotifyOnCompletion(_ on: Bool) {
        notifyOnCompletion = on
        defaults.set(on, forKey: Key.notifyOnCompletion)
    }

    static func intervalLabel(_ hours: Int) -> String {
        switch hours {
        case 0: return "Off"
        case 1: return "Every hour"
        case 24: return "Daily"
        default: return "Every \(hours) hours"
        }
    }
}
