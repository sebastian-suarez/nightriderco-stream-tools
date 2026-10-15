//
//  KeychainStoreTests.swift
//  StreamMenuBarTests
//
//  These run inside the app process (TEST_HOST), so they exercise the data-protection
//  keychain with the app's real entitlements.
//

import Foundation
import Testing
@testable import StreamMenuBar

struct KeychainStoreTests {
    private let store = KeychainStore(service: "dev.sebastiansuarez.StreamMenuBar.tests")

    @Test func roundTripsUpdatesAndRemoves() throws {
        let account = "round-trip-\(UUID().uuidString)"
        defer { try? store.remove(account) }

        #expect(try store.data(for: account) == nil)
        try store.set(Data("first".utf8), for: account)
        #expect(try store.data(for: account) == Data("first".utf8))
        try store.set(Data("second".utf8), for: account)
        #expect(try store.data(for: account) == Data("second".utf8))
        try store.remove(account)
        #expect(try store.data(for: account) == nil)
        try store.remove(account)
    }

    @Test func storesCodableValues() throws {
        let account = "codable-\(UUID().uuidString)"
        defer { try? store.remove(account) }

        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 42), scope: "user:read")
        try store.set(tokens, for: account)
        #expect(try store.value(OAuthTokens.self, for: account) == tokens)
    }
}
