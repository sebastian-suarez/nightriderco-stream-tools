//
//  KickOAuth.swift
//  StreamMenuBar
//

import CryptoKit
import Foundation
import os

/// Kick's OAuth 2.1 endpoints and the parameters this app uses with them
/// (docs.kick.com, "generating-tokens-oauth2-flow").
nonisolated enum KickOAuth {
    static let authorizeEndpoint = URL(string: "https://id.kick.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://id.kick.com/oauth/token")!
    static let revokeEndpoint = URL(string: "https://id.kick.com/oauth/revoke")!
    static let introspectEndpoint = URL(string: "https://id.kick.com/oauth/token/introspect")!

    /// `user:read` for GET /public/v1/users, `channel:read` for GET /public/v1/channels.
    static let scopes = ["user:read", "channel:read"]

    /// Port of the loopback listener that receives the redirect. The redirect URL registered
    /// on the Kick app must be exactly `redirectURI`; Kick's docs recommend `localhost`
    /// (not 127.0.0.1) for locally running apps.
    static let redirectPort: UInt16 = 8732
    static let redirectPath = "/callback"
    static let redirectURI = "http://localhost:\(redirectPort)\(redirectPath)"

    static func authorizationURL(clientID: String, codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        // Form-style encoding (`+` between scopes, `%3A` for colons) is what clients known to work
        // against Kick send. With the space encoded as `%20`, Kick granted only the first scope.
        components.percentEncodedQuery = FormEncoding.encode([
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", scopes.joined(separator: " ")),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ])
        return components.url!
    }
}

/// PKCE (RFC 7636) verifier and its S256 challenge.
nonisolated struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    init() {
        self.init(verifier: PKCE.randomURLSafeString(byteCount: 32))
    }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// `byteCount` random bytes from the system CSPRNG, base64url-encoded without padding.
    static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The client ID and secret of the Kick app the user registered at kick.com/settings/developer.
nonisolated struct KickAppCredentials: Codable, Sendable, Equatable {
    var clientID: String
    var clientSecret: String
}

/// The user's tokens as stored in the Keychain.
nonisolated struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// nil when the token response carried no `expires_in`; the token is then used until Kick rejects it.
    var expiresAt: Date?
    var scope: String?

    func isExpiring(within leeway: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// Body of a successful response from the token endpoint.
nonisolated struct KickTokenResponse: Decodable, Sendable {
    var accessToken: String
    var tokenType: String?
    var refreshToken: String?
    var expiresIn: TimeInterval?
    var scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        // The docs show expires_in as a number (seconds); accept a numeric string too.
        if let seconds = try? container.decode(Double.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? container.decode(String.self, forKey: .expiresIn), let seconds = Double(text) {
            expiresIn = seconds
        } else {
            expiresIn = nil
        }
    }

    func tokens(issuedAt: Date = Date()) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { issuedAt.addingTimeInterval($0) },
            scope: scope
        )
    }
}

/// Error body from the token endpoint (`error`, `error_description`) or Kick's `message` envelope.
nonisolated struct OAuthErrorResponse: Decodable, Sendable {
    var error: String?
    var errorDescription: String?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message
    }
}

/// application/x-www-form-urlencoded: everything but unreserved characters is percent-encoded,
/// and a space becomes `+`. Used for token request bodies and the authorize URL's query.
nonisolated enum FormEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        // A literal "+" was already encoded as %2B above, so the replacement is unambiguous.
        (text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text)
            .replacingOccurrences(of: "%20", with: "+")
    }
}

/// Token endpoint calls. Every one of them needs the client secret (Kick requires it even with PKCE).
nonisolated struct KickOAuthClient: Sendable {
    var session: URLSession = .shared

    @concurrent
    func exchangeCode(_ code: String, codeVerifier: String, credentials: KickAppCredentials) async throws -> OAuthTokens {
        try await requestTokens(form: [
            ("grant_type", "authorization_code"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("redirect_uri", KickOAuth.redirectURI),
            ("code_verifier", codeVerifier),
            ("code", code),
        ])
    }

    @concurrent
    func refresh(refreshToken: String, credentials: KickAppCredentials) async throws -> OAuthTokens {
        try await requestTokens(form: [
            ("grant_type", "refresh_token"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("refresh_token", refreshToken),
        ])
    }

    /// Best-effort revocation on sign-out. `hint` is "access_token" or "refresh_token".
    @concurrent
    func revoke(token: String, hint: String) async throws {
        var components = URLComponents(url: KickOAuth.revokeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "token_hint_type", value: hint),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamProviderError.invalidResponse("Not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StreamProviderError.httpStatus(http.statusCode, body: Self.excerpt(data))
        }
    }

    /// Diagnostics only: asks Kick whether it considers an access token active, and with which scope.
    @concurrent
    func introspect(accessToken: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: KickOAuth.introspectEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamProviderError.invalidResponse("Not an HTTP response")
        }
        return (http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
    }

    private func requestTokens(form: [(String, String)]) async throws -> OAuthTokens {
        var request = URLRequest(url: KickOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode(form).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamProviderError.invalidResponse("Not an HTTP response")
        }
        let grant = form.first { $0.0 == "grant_type" }?.1 ?? "?"
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data), let code = body.error {
                Log.auth.error("Token request (\(grant, privacy: .public)) failed: HTTP \(http.statusCode) \(code, privacy: .public): \(body.errorDescription ?? body.message ?? "", privacy: .public)")
                throw StreamProviderError.oauth(code: code, description: body.errorDescription ?? body.message)
            }
            Log.auth.error("Token request (\(grant, privacy: .public)) failed: HTTP \(http.statusCode) \(Self.excerpt(data), privacy: .public)")
            throw StreamProviderError.httpStatus(http.statusCode, body: Self.excerpt(data))
        }
        do {
            let tokens = try JSONDecoder().decode(KickTokenResponse.self, from: data).tokens()
            Log.auth.info("Token request (\(grant, privacy: .public)) succeeded; expires in \(tokens.expiresAt.map { Int($0.timeIntervalSinceNow) } ?? -1) s, scope: \(tokens.scope ?? "none", privacy: .public), refresh token: \(tokens.refreshToken == nil ? "no" : "yes", privacy: .public)")
            return tokens
        } catch {
            Log.auth.error("Token response could not be decoded: \(error.localizedDescription, privacy: .public)")
            throw StreamProviderError.invalidResponse("token response: \(error.localizedDescription)")
        }
    }

    static func excerpt(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }
}
