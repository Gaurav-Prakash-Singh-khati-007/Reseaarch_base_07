//
//  KeychainStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 2 · Features: F-56 (secrets in Keychain)
//  The Keychain tests use their own throwaway service name and clean up
//  after themselves, so they never touch real ResearchBase keys. If the
//  test run is not allowed to use the Keychain (locked, no entitlement),
//  those tests are skipped instead of failing.
//

import XCTest
import Security
@testable import ResearchBase

@MainActor
final class KeychainStoreTests: XCTestCase {

    private var service = ""
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        service = "ResearchBase.tests.\(UUID().uuidString)"
        store = KeychainStore(service: service)
    }

    override func tearDown() {
        for name in SecretName.all + [SecretName("custom-key")] {
            try? store.delete(name)
        }
        store = nil
        super.tearDown()
    }

    /// Runs a Keychain action; skips the test when this environment cannot use the Keychain.
    private func keychain<T>(_ action: () throws -> T) throws -> T {
        do {
            return try action()
        } catch SecretStoreError.keychain(let status)
            where status == errSecMissingEntitlement
                || status == errSecInteractionNotAllowed
                || status == errSecNotAvailable
                || status == errSecAuthFailed {
            throw XCTSkip("The Keychain is not available to this test run (status \(status)).")
        }
    }

    // MARK: Real Keychain

    func testSaveReadOverwriteDelete() throws {
        XCTAssertNil(try keychain { try store.read(.openAlexAPIKey) })

        try keychain { try store.save("first-value-1234", for: .openAlexAPIKey) }
        XCTAssertEqual(try store.read(.openAlexAPIKey), "first-value-1234")
        XCTAssertTrue(store.contains(.openAlexAPIKey))

        try store.save("second-value-5678", for: .openAlexAPIKey)
        XCTAssertEqual(try store.read(.openAlexAPIKey), "second-value-5678")

        try store.delete(.openAlexAPIKey)
        XCTAssertNil(try store.read(.openAlexAPIKey))
        XCTAssertFalse(store.contains(.openAlexAPIKey))
    }

    func testDeletingAMissingSecretIsNotAnError() throws {
        try keychain { try store.delete(SecretName("custom-key")) }
    }

    func testValueIsTrimmedAndEmptyIsRefused() throws {
        try keychain { try store.save("  abc123  \n", for: SecretName("custom-key")) }
        XCTAssertEqual(try store.read(SecretName("custom-key")), "abc123")

        XCTAssertThrowsError(try store.save("   \n", for: SecretName("custom-key"))) { error in
            XCTAssertEqual(error as? SecretStoreError, .emptyValue)
        }
        // The refused save did not erase the old value.
        XCTAssertEqual(try store.read(SecretName("custom-key")), "abc123")
    }

    func testDifferentServicesDoNotSeeEachOther() throws {
        let other = KeychainStore(service: service + ".other")
        defer { try? other.delete(.crossrefPlusToken) }

        try keychain { try store.save("only-in-first-1234", for: .crossrefPlusToken) }
        XCTAssertNil(try other.read(.crossrefPlusToken))
    }

    // MARK: In memory

    func testInMemoryStoreBehavesTheSameWay() throws {
        let memory = InMemorySecretStore()
        XCTAssertNil(try memory.read(.semanticScholarAPIKey))

        try memory.save("  key-value-9999 ", for: .semanticScholarAPIKey)
        XCTAssertEqual(try memory.read(.semanticScholarAPIKey), "key-value-9999")
        XCTAssertTrue(memory.contains(.semanticScholarAPIKey))

        XCTAssertThrowsError(try memory.save("", for: .semanticScholarAPIKey))

        try memory.delete(.semanticScholarAPIKey)
        try memory.delete(.semanticScholarAPIKey)
        XCTAssertNil(try memory.read(.semanticScholarAPIKey))
    }

    func testInMemoryStoreCanStartWithValues() throws {
        let memory = InMemorySecretStore([.openAlexAPIKey: "preset-key-0000"])
        XCTAssertEqual(try memory.read(.openAlexAPIKey), "preset-key-0000")
        XCTAssertFalse(memory.contains(.crossrefPlusToken))
    }

    // MARK: Names, masking, messages

    func testKnownNamesAreDistinctAndHaveLabels() {
        XCTAssertEqual(Set(SecretName.all.map(\.rawValue)).count, SecretName.all.count)
        XCTAssertEqual(SecretName.openAlexAPIKey.displayName, "OpenAlex API key")
        XCTAssertEqual(SecretName("my-own-key").displayName, "my-own-key")
        let literal: SecretName = "from-a-literal"
        XCTAssertEqual(literal.rawValue, "from-a-literal")
    }

    func testMaskingNeverShowsMoreThanTheLastFourCharacters() {
        XCTAssertEqual(SecretMask.masked("sk-abcdefghijklmnop1234"), "••••1234")
        XCTAssertEqual(SecretMask.masked("short"), "••••")
        XCTAssertFalse(SecretMask.masked("sk-abcdefghijklmnop1234").contains("abcdef"))
    }

    func testErrorsReadInPlainWords() {
        XCTAssertEqual(SecretStoreError.emptyValue.errorDescription, "The key is empty, so nothing was saved.")
        XCTAssertTrue(SecretStoreError.keychain(errSecInteractionNotAllowed).errorDescription?.contains("locked") == true)
        XCTAssertTrue(SecretStoreError.keychain(errSecUserCanceled).errorDescription?.contains("cancelled") == true)
        XCTAssertFalse((SecretStoreError.keychain(-99999).errorDescription ?? "").isEmpty)
    }
}
