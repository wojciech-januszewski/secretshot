import Foundation

/// UserDefaults-backed preferences. No config file, no telemetry, no network.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let enabledRules = "enabledRules"
        static let style = "redactionStyle"
        static let watchPasteboard = "watchPasteboard"
        static let verifyAfterRedaction = "verifyAfterRedaction"
    }

    private init() {}

    var enabledRules: Set<String> {
        get {
            guard let stored = defaults.array(forKey: Key.enabledRules) as? [String] else {
                return Set(Detectors.all.filter(\.defaultEnabled).map(\.id))
            }
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Key.enabledRules) }
    }

    func toggleRule(_ id: String) {
        var rules = enabledRules
        if rules.contains(id) { rules.remove(id) } else { rules.insert(id) }
        enabledRules = rules
    }

    var style: RedactionStyle {
        get { RedactionStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .solid }
        set { defaults.set(newValue.rawValue, forKey: Key.style) }
    }

    var watchPasteboard: Bool {
        get { defaults.object(forKey: Key.watchPasteboard) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.watchPasteboard) }
    }

    var verifyAfterRedaction: Bool {
        get { defaults.object(forKey: Key.verifyAfterRedaction) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.verifyAfterRedaction) }
    }
}
