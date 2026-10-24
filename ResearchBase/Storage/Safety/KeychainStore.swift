//
//  KeychainStore.swift
//  ResearchBase
//
//  Owner: Agent 2 · Features: F-56 (secrets in Keychain)
//
//  Optional API keys and tokens live in the macOS Keychain, never in the
//  library folder, the database, the backups or the exports.
//
//  PUBLIC API
//  ----------
//  SecretName                     a named secret; known names below, or SecretName("my-key")
//    .semanticScholarAPIKey, .openAlexAPIKey, .crossrefPlusToken, .all
//    .displayName                 label for a Settings row
//  SecretStore (protocol)         read(_:) -> String?   (nil = not set)
//                                 save(_:for:)          (trims; empty value is refused)
//                                 delete(_:)            (deleting a missing secret is fine)
//                                 contains(_:) -> Bool
//  KeychainStore                  the real thing. KeychainStore.shared, or
//                                 KeychainStore(service:) for a separate namespace
//  InMemorySecretStore            same API, nothing stored on disk (tests, previews)
//  SecretMask.masked(_:)          "••••1234" for showing a saved key in a screen
//  SecretStoreError               plain-language LocalizedError
//
//  Notes
//  - Uses the login keychain (no special entitlement needed). Secrets are
//    marked as not syncing to iCloud Keychain.
//  - Code that needs a key takes a `SecretStore` so tests can pass an
//    InMemorySecretStore. Never log a secret; AppLogger also redacts them.
//

import Foundation
import Security

// MARK: - Names

nonisolated struct SecretName: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    static let semanticScholarAPIKey = SecretName("semantic-scholar-api-key")
    static let openAlexAPIKey = SecretName("openalex-api-key")
    static let crossrefPlusToken = SecretName("crossref-plus-token")

    static let all: [SecretName] = [.semanticScholarAPIKey, .openAlexAPIKey, .crossrefPlusToken]

    var displayName: String {
        switch self {
        case .semanticScholarAPIKey: return "Semantic Scholar API key"
        case .openAlexAPIKey: return "OpenAlex API key"
        case .crossrefPlusToken: return "Crossref Plus token"
        default: return rawValue
        }
    }
}

// MARK: - Errors

nonisolated enum SecretStoreError: LocalizedError, Equatable {

    case emptyValue
    case notText
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyValue:
            return "The key is empty, so nothing was saved."
        case .notText:
            return "The saved key could not be read as text."
        case .keychain(let status):
            switch status {
            case errSecInteractionNotAllowed:
                return "The Keychain is locked. Unlock your Mac and try again."
            case errSecUserCanceled:
                return "Keychain access was cancelled."
            case errSecAuthFailed:
                return "The Keychain did not accept your password."
            case errSecMissingEntitlement:
                return "ResearchBase is not allowed to use the Keychain in this build."
            default:
                let system = SecCopyErrorMessageString(status, nil) as String?
                return "The Keychain reported a problem" + (system.map { ": \($0)" } ?? " (code \(status)).")
            }
        }
    }
}

// MARK: - Protocol

nonisolated protocol SecretStore: Sendable {
    /// The saved value, or nil when nothing is saved under this name.
    func read(_ name: SecretName) throws -> String?
    /// Saves (or replaces) a value. Surrounding spaces and line breaks are removed.
    func save(_ value: String, for name: SecretName) throws
    /// Removes a value. Removing something that is not there is not an error.
    func delete(_ name: SecretName) throws
}

extension SecretStore {
    func contains(_ name: SecretName) -> Bool {
        ((try? read(name)) ?? nil) != nil
    }
}

// MARK: - Display helper

nonisolated enum SecretMask {

    /// Shows only the last four characters of a long key, e.g. "••••a1b2".
    /// Short values show no characters at all.
    static func masked(_ value: String) -> String {
        value.count >= 12 ? "••••" + value.suffix(4) : "••••"
    }
}

// MARK: - The real Keychain

nonisolated struct KeychainStore: SecretStore {

    static let defaultService = "ResearchBase"
    static let shared = KeychainStore()

    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func read(_ name: SecretName) throws -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.notText
            }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    func save(_ value: String, for name: SecretName) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecretStoreError.emptyValue }
        let data = Data(trimmed.utf8)

        var add = baseQuery(name)
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(name) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw SecretStoreError.keychain(updateStatus) }
        } else if addStatus != errSecSuccess {
            throw SecretStoreError.keychain(addStatus)
        }
    }

    func delete(_ name: SecretName) throws {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }

    private func baseQuery(_ name: SecretName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name.rawValue,
            // Never sync secrets to iCloud Keychain.
            kSecAttrSynchronizable as String: false
        ]
    }
}

// MARK: - In memory (tests and previews)

nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {

    private let lock = NSLock()
    private var values: [SecretName: String] = [:]

    init(_ initial: [SecretName: String] = [:]) {
        values = initial
    }

    func read(_ name: SecretName) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[name]
    }

    func save(_ value: String, for name: SecretName) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecretStoreError.emptyValue }
        lock.lock(); defer { lock.unlock() }
        values[name] = trimmed
    }

    func delete(_ name: SecretName) throws {
        lock.lock(); defer { lock.unlock() }
        values[name] = nil
    }
}
