import Foundation

/// Tracks which whispers the user has already found (so we don't notify again),
/// and throttles repeat notifications per whisper with a cooldown.
enum FoundAndNotifyStore {
    private static let foundKey = "et_found_whisper_ids"          // [String]
    private static let notifiedKey = "et_last_notified"           // [id: TimeInterval]

    // MARK: Found (user has opened/played it)

    static func markFound(_ id: String) {
        var set = foundSet()
        set.insert(id)
        saveFound(set)
    }

    static func isFound(_ id: String) -> Bool {
        foundSet().contains(id)
    }

    // MARK: Notification throttle (cooldown in seconds; default 2 hours)

    /// Returns true if we should notify now; records the timestamp when it does.
    static func shouldNotify(_ id: String, cooldown: TimeInterval = 2 * 60 * 60) -> Bool {
        let now = Date().timeIntervalSince1970
        var dict = lastNotifiedDict()
        if let last = dict[id], (now - last) < cooldown { return false }
        dict[id] = now
        saveLastNotified(dict)
        return true
    }

    // MARK: - Internal persistence

    private static func foundSet() -> Set<String> {
        let arr = UserDefaults.standard.array(forKey: foundKey) as? [String] ?? []
        return Set(arr)
    }

    private static func saveFound(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: foundKey)
    }

    private static func lastNotifiedDict() -> [String: TimeInterval] {
        UserDefaults.standard.dictionary(forKey: notifiedKey) as? [String: TimeInterval] ?? [:]
    }

    private static func saveLastNotified(_ d: [String: TimeInterval]) {
        UserDefaults.standard.set(d, forKey: notifiedKey)
    }

    // Optional helpers for QA
    static func resetFound() { UserDefaults.standard.removeObject(forKey: foundKey) }
    static func resetNotified() { UserDefaults.standard.removeObject(forKey: notifiedKey) }
}
