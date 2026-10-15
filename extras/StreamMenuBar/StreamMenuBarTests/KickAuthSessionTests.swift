//
//  KickAuthSessionTests.swift
//  StreamMenuBarTests
//

import Foundation
import Synchronization
import Testing
@testable import StreamMenuBar

@Suite(.serialized)
final class KickAuthSessionTests {
    private let keychain = KeychainStore(service: "dev.sebastiansuarez.StreamMenuBar.tests.\(UUID().uuidString)")
    private let credentials = KickAppCredentials(clientID: "client-1", clientSecret: "secret-1")
    private static let channelJSON = Data(#"{"data":[{"slug":"somestreamer","stream":{"is_live":true,"viewer_count":42}}],"message":""}"#.utf8)

    deinit {
        try? keychain.remove(KickAuthSession.credentialsAccount)
        try? keychain.remove(KickAuthSession.tokensAccount)
        StubURLProtocol.install(nil)
    }

    private func makeSession() -> KickAuthSession {
        KickAuthSession(keychain: keychain, oauth: KickOAuthClient(session: StubURLProtocol.session()))
    }

    /// Handlers run on URLSession's queue and may outlive the test: they must not capture `self`.
    private func stub(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.install(handler)
    }

    private static func tokenJSON(access: String, refresh: String? = "rt-2") -> Data {
        let refreshField = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
        return Data(#"{"access_token":"\#(access)"\#(refreshField),"expires_in":7200,"token_type":"Bearer"}"#.utf8)
    }

    @Test func exchangesCodeAndStoresTokens() async throws {
        let recorder = Recorder()
        stub { request, body in
            recorder.record("\(request.url!.absoluteString) \(String(decoding: body, as: UTF8.self))")
            return (200, Self.tokenJSON(access: "at-1", refresh: "rt-1"))
        }
        let session = makeSession()
        try await session.storeCredentials(credentials)
        #expect(try await session.isSignedIn() == false)

        try await session.completeSignIn(code: "the-code", codeVerifier: "the-verifier")

        #expect(try await session.isSignedIn())
        #expect(try await session.validAccessToken() == "at-1")
        let request = try #require(recorder.entries.first)
        #expect(request.hasPrefix(KickOAuth.tokenEndpoint.absoluteString + " "))
        #expect(request.contains("grant_type=authorization_code"))
        #expect(request.contains("client_id=client-1"))
        #expect(request.contains("client_secret=secret-1"))
        #expect(request.contains("redirect_uri=http%3A%2F%2Flocalhost%3A8732%2Fcallback"))
        #expect(request.contains("code_verifier=the-verifier"))
        #expect(request.contains("code=the-code"))
        let stored = try keychain.value(OAuthTokens.self, for: KickAuthSession.tokensAccount)
        #expect(stored?.accessToken == "at-1")
        #expect(stored?.refreshToken == "rt-1")
    }

    @Test func refreshesWhenAccessTokenIsAboutToExpire() async throws {
        let recorder = Recorder()
        stub { _, body in
            recorder.record(String(decoding: body, as: UTF8.self))
            return (200, Self.tokenJSON(access: "at-2", refresh: nil))
        }
        try keychain.set(credentials, for: KickAuthSession.credentialsAccount)
        let expiring = OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: Date().addingTimeInterval(30), scope: nil)
        try keychain.set(expiring, for: KickAuthSession.tokensAccount)

        let session = makeSession()
        #expect(try await session.validAccessToken() == "at-2")
        #expect(recorder.entries == ["grant_type=refresh_token&client_id=client-1&client_secret=secret-1&refresh_token=rt-1"])

        // The fresh token is reused, and the old refresh token is kept when Kick does not rotate it.
        #expect(try await session.validAccessToken() == "at-2")
        #expect(recorder.entries.count == 1)
        let stored = try keychain.value(OAuthTokens.self, for: KickAuthSession.tokensAccount)
        #expect(stored?.accessToken == "at-2")
        #expect(stored?.refreshToken == "rt-1")
    }

    @Test func invalidGrantEndsTheSession() async throws {
        stub { _, _ in
            (400, Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8))
        }
        try keychain.set(credentials, for: KickAuthSession.credentialsAccount)
        let expired = OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: Date().addingTimeInterval(-10), scope: nil)
        try keychain.set(expired, for: KickAuthSession.tokensAccount)

        let session = makeSession()
        await #expect(throws: StreamProviderError.reauthorizationRequired(reason: "Refresh token revoked")) {
            try await session.validAccessToken()
        }
        #expect(try await session.isSignedIn() == false)
        #expect(try keychain.data(for: KickAuthSession.tokensAccount) == nil)
    }

    @Test func apiClientRefreshesAndRetriesOnceAfterUnauthorized() async throws {
        let recorder = Recorder()
        stub { request, _ in
            recorder.record(request.url!.path)
            if request.url == KickOAuth.tokenEndpoint {
                return (200, Self.tokenJSON(access: "at-2"))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2" {
                return (200, Self.channelJSON)
            }
            return (401, Data(#"{"data":null,"message":"Unauthorized"}"#.utf8))
        }
        try keychain.set(credentials, for: KickAuthSession.credentialsAccount)
        try keychain.set(OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: nil, scope: nil), for: KickAuthSession.tokensAccount)

        let session = makeSession()
        let provider = KickStreamProvider(api: KickAPIClient(auth: session, session: StubURLProtocol.session()))
        let snapshot = try await provider.fetchSnapshot()

        #expect(snapshot.channelName == "somestreamer")
        #expect(snapshot.isLive == true)
        #expect(snapshot.viewerCount == 42)
        #expect(recorder.entries == ["/public/v1/channels", "/oauth/token/introspect", "/oauth/token", "/public/v1/channels"])
    }

    @Test func persistentUnauthorizedAsksForSignInButKeepsTokens() async throws {
        stub { request, _ in
            if request.url == KickOAuth.tokenEndpoint {
                return (200, Self.tokenJSON(access: "at-2"))
            }
            return (401, Data(#"{"data":null,"message":"Unauthorized"}"#.utf8))
        }
        try keychain.set(credentials, for: KickAuthSession.credentialsAccount)
        try keychain.set(OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: nil, scope: nil), for: KickAuthSession.tokensAccount)

        let session = makeSession()
        let provider = KickStreamProvider(api: KickAPIClient(auth: session, session: StubURLProtocol.session()))
        let expected = StreamProviderError.reauthorizationRequired(reason: #"Kick rejected the access token: {"data":null,"message":"Unauthorized"}"#)
        await #expect(throws: expected) {
            try await provider.fetchSnapshot()
        }
        #expect(try await session.isSignedIn())
        #expect(try keychain.value(OAuthTokens.self, for: KickAuthSession.tokensAccount)?.accessToken == "at-2")
    }

    @Test func savingADifferentClientIDForgetsTheTokens() async throws {
        try keychain.set(credentials, for: KickAuthSession.credentialsAccount)
        try keychain.set(OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: nil, scope: nil), for: KickAuthSession.tokensAccount)

        let session = makeSession()
        try await session.storeCredentials(KickAppCredentials(clientID: " client-1 ", clientSecret: "rotated"))
        #expect(try await session.isSignedIn())
        try await session.storeCredentials(KickAppCredentials(clientID: "client-2", clientSecret: "secret-2"))
        #expect(try await session.isSignedIn() == false)
        #expect(try await session.credentials() == KickAppCredentials(clientID: "client-2", clientSecret: "secret-2"))
    }
}
