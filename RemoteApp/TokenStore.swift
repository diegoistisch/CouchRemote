import Foundation
import Security

/// Speichert das Kopplungs-Token pro Mac im Schlüsselbund des iPhones.
enum TokenStore {
    private static let service = "at.diego.couchremote.token"

    static func token(for mac: String) -> String? {
        var query = baseQuery(mac)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for mac: String) {
        delete(for: mac)
        var query = baseQuery(mac)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(for mac: String) {
        SecItemDelete(baseQuery(mac) as CFDictionary)
    }

    private static func baseQuery(_ mac: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac
        ]
    }
}
