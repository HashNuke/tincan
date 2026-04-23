#if os(macOS)
import Foundation
import Security

struct MacKeychainService {
    static let serviceName = "com.definerun.tincan"
    static let legacyServiceNames = ["com.tincanbot"]

    func containsValue(account: String) throws -> Bool {
        if try containsValue(account: account, service: Self.serviceName) {
            return true
        }

        for legacyServiceName in Self.legacyServiceNames {
            if try containsValue(account: account, service: legacyServiceName) {
                return true
            }
        }

        return false
    }

    func value(account: String) throws -> String? {
        if let currentValue = try value(account: account, service: Self.serviceName) {
            return currentValue
        }

        for legacyServiceName in Self.legacyServiceNames {
            guard let legacyValue = try value(account: account, service: legacyServiceName) else {
                continue
            }

            // Migrate legacy items into the bundle-matched namespace on first successful read.
            try upsert(value: legacyValue, account: account, service: Self.serviceName)
            try? deleteValue(account: account, service: legacyServiceName)
            return legacyValue
        }

        return nil
    }

    func upsert(value: String, account: String) throws {
        try upsert(value: value, account: account, service: Self.serviceName)
        try deleteLegacyValues(account: account)
    }

    func deleteValue(account: String) throws {
        try deleteValue(account: account, service: Self.serviceName)
        try deleteLegacyValues(account: account)
    }

    private func containsValue(account: String, service: String) throws -> Bool {
        let status = SecItemCopyMatching(baseQuery(account: account, service: service) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainError(status: status)
        }
    }

    private func value(account: String, service: String) throws -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private func upsert(value: String, account: String, service: String) throws {
        let query = baseQuery(account: account, service: service)
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    private func deleteValue(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func deleteLegacyValues(account: String) throws {
        for legacyServiceName in Self.legacyServiceNames {
            try deleteValue(account: account, service: legacyServiceName)
        }
    }

    private func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var isNonFatalReadAuthorizationFailure: Bool {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain operation failed (\(status))."
    }
}
#endif
