//
//  PKCETests.swift
//  StreamMenuBarTests
//

import Foundation
import Testing
@testable import StreamMenuBar

struct PKCETests {
    @Test func challengeMatchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsURLSafeAndUnique() {
        let pkce = PKCE()
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.count == 43)
        #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
        #expect(pkce.challenge.allSatisfy { allowed.contains($0) })
        #expect(PKCE().verifier != pkce.verifier)
    }

    @Test func authorizationURLCarriesEveryParameter() throws {
        let url = KickOAuth.authorizationURL(clientID: "client-1", codeChallenge: "challenge-1", state: "state-1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "id.kick.com")
        #expect(components.path == "/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "client-1")
        #expect(query["redirect_uri"] == "http://localhost:8732/callback")
        #expect(query["code_challenge"] == "challenge-1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state-1")
        // Kick wants the scope list form-encoded: "+" between scopes, colons as %3A.
        let raw = try #require(components.percentEncodedQuery)
        #expect(raw.contains("scope=user%3Aread+channel%3Aread"))
        #expect(raw.contains("redirect_uri=http%3A%2F%2Flocalhost%3A8732%2Fcallback"))
        #expect(!raw.contains("%20"))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let encoded = FormEncoding.encode([("a b", "c&d=e/f+g"), ("plain", "x~y")])
        #expect(encoded == "a+b=c%26d%3De%2Ff%2Bg&plain=x~y")
    }
}
