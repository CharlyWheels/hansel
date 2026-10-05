import Foundation
import Security

/// Tiny Keychain wrapper for storing AI provider API tokens under the app's service.
enum KeychainStore {
    /// Matches the bundle identifier.
    private static let service = "com.carlosrueda.hansel"
    /// Where keys were stored before the app was renamed. Read once and moved.
    private static let legacyService = "com.carlosrueda.timetracker"

    /// Stores `value`, updating in place when the item exists.
    ///
    /// The old version deleted first and then added, so a failed add (locked keychain,
    /// access denied) silently lost the existing key. Returns whether it was stored.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = query
            attrs[kSecValueData as String] = data
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        if status != errSecSuccess {
            AppLogger.persistence.error("Keychain set failed key=\(key, privacy: .public) status=\(status)")
            AppLogger.log("persistence", level: .error, "keychain_set_failed status=\(status)")
        }
        return status == errSecSuccess
    }

    /// Whether a value exists, without reading the secret itself.
    static func contains(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
            || get(key) != nil
    }

    static func get(_ key: String) -> String? {
        if let value = read(key, service: service) { return value }
        // Move a key saved under the old service name, so it is not lost.
        guard let legacy = read(key, service: legacyService) else { return nil }
        if set(legacy, for: key) { deleteItem(key, service: legacyService) }
        return legacy
    }

    private static func read(_ key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound {
            // Distinguish "no key" from "could not read it" in the logs at least;
            // both still read as "not configured" to callers.
            AppLogger.log("persistence", level: .error, "keychain_get_failed status=\(status)")
        }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        deleteItem(key, service: service)
        deleteItem(key, service: legacyService)
    }

    private static func deleteItem(_ key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
