import Foundation

extension UserDefaults {
    /// Bool setting with a default. Unlike `object as? Bool` it also reads launch arguments (`-key NO`), which arrive as strings.
    func flag(_ key: String, _ fallback: Bool) -> Bool { object(forKey: key) == nil ? fallback : bool(forKey: key) }
}
