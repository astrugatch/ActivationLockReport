import Foundation
import Security

struct StoredASMCredentials: Codable, Equatable, Sendable {
    var clientId: String
    var keyId: String
    var pemContent: String
    var pemFileName: String

    static let empty = StoredASMCredentials(
        clientId: "",
        keyId: "",
        pemContent: "",
        pemFileName: ""
    )

    var isEmpty: Bool {
        clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        keyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        pemContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum KeychainHelper {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.asm.ActivationLockStatus"
    }
    private static let account = "asm_api_credentials"

    static func loadCredentials() throws -> StoredASMCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            return nil
        }

        return try JSONDecoder().decode(StoredASMCredentials.self, from: data)
    }

    static func saveCredentials(_ credentials: StoredASMCredentials) throws {
        if credentials.isEmpty {
            try deleteCredentials()
            return
        }

        let data = try JSONEncoder().encode(credentials)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        // Update in place first so existing Keychain access permissions stay intact
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecAttrLabel as String] = "Apple School Manager API Credentials"
            addQuery[kSecValueData as String] = data

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }

        throw KeychainError.unexpectedStatus(updateStatus)
    }

    static func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
