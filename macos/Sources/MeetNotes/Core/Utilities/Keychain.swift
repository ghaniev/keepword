import Foundation
import Security

enum Keychain {
    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "MeetNotes", kSecAttrAccount: key]
    }

    static func get(_ key: String) -> String {
        var q = query(key)
        q[kSecReturnData] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ key: String, _ value: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
