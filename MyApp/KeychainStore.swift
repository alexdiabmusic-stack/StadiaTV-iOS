import Foundation
import Security

struct XtreamCredentials: Codable, Hashable {
    let username: String
    let password: String
}

enum KeychainStore {
    private static let service = "com.alexdiab.StadiaTV.xtream"

    static func saveXtreamCredentials(_ credentials: XtreamCredentials, for playlistID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let account = playlistID.uuidString
        deleteXtreamCredentials(for: playlistID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
    }

    static func xtreamCredentials(for playlistID: UUID) throws -> XtreamCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: playlistID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unhandledStatus(status)
        }
        return try JSONDecoder().decode(XtreamCredentials.self, from: data)
    }

    static func deleteXtreamCredentials(for playlistID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: playlistID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: LocalizedError {
        case unhandledStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandledStatus(let status):
                return "Keychain returned status \(status)."
            }
        }
    }
}
