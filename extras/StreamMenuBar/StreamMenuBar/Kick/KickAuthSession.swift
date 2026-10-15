//
//  KickAuthSession.swift
//  StreamMenuBar
//

import Foundation

/// Owns the Kick app credentials and the user's OAuth tokens: loads them from the Keychain,
/// hands out a valid access token, refreshes before expiry, and clears the session when Kick
/// rejects the refresh token. An actor, so it runs off the main actor and serializes refreshes.
actor KickAuthSession {
    static let credentialsAccount = "kick.app-credentials"
    static let tokensAccount = "kick.user-tokens"
    /// Refresh when the access token expires within this many seconds.
    static let refreshLeeway: TimeInterval = 60

    private let keychain: KeychainStore
    private let oauth: KickOAuthClient
    private var hasLoaded = false
    private var cachedCredentials: KickAppCredentials?
    private var cachedTokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, any Error>?

    init(keychain: KeychainStore = .app, oauth: KickOAuthClient = KickOAuthClient()) {
        self.keychain = keychain
        self.oauth = oauth
    }

    // MARK: Credentials

    func credentials() throws -> KickAppCredentials? {
        try loadIfNeeded()
        return cachedCredentials
    }

    func storeCredentials(_ credentials: KickAppCredentials) throws {
        try loadIfNeeded()
        let trimmed = KickAppCredentials(
            clientID: credentials.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: credentials.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Tokens belong to the app that issued them.
        if let current = cachedCredentials, current.clientID != trimmed.clientID {
            try clearTokens()
        }
        try keychain.set(trimmed, for: Self.credentialsAccount)
        cachedCredentials = trimmed
    }

    // MARK: Tokens

    func isSignedIn() throws -> Bool {
        try loadIfNeeded()
        return cachedTokens != nil
    }

    /// The current access token, refreshed first if it is about to expire.
    func validAccessToken() async throws -> String {
        try loadIfNeeded()
        guard let tokens = cachedTokens else { throw StreamProviderError.notSignedIn }
        if !tokens.isExpiring(within: Self.refreshLeeway) {
            return tokens.accessToken
        }
        return try await refreshTokens().accessToken
    }

    /// Refreshes once even when several callers ask at the same time.
    func refreshTokens() async throws -> OAuthTokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func completeSignIn(code: String, codeVerifier: String) async throws {
        try loadIfNeeded()
        guard let credentials = cachedCredentials else { throw StreamProviderError.missingCredentials }
        let tokens = try await oauth.exchangeCode(code, codeVerifier: codeVerifier, credentials: credentials)
        try keychain.set(tokens, for: Self.tokensAccount)
        cachedTokens = tokens
    }

    /// Forgets the tokens and revokes the refresh token on a best-effort basis.
    func signOut() async {
        try? loadIfNeeded()
        let tokens = cachedTokens
        try? clearTokens()
        if let refreshToken = tokens?.refreshToken {
            try? await oauth.revoke(token: refreshToken, hint: "refresh_token")
        }
    }

    // MARK: Private

    private func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        cachedCredentials = try keychain.value(KickAppCredentials.self, for: Self.credentialsAccount)
        cachedTokens = try keychain.value(OAuthTokens.self, for: Self.tokensAccount)
        hasLoaded = true
    }

    private func performRefresh() async throws -> OAuthTokens {
        try loadIfNeeded()
        guard let credentials = cachedCredentials else { throw StreamProviderError.missingCredentials }
        guard let current = cachedTokens else { throw StreamProviderError.notSignedIn }
        guard let refreshToken = current.refreshToken else {
            try? clearTokens()
            throw StreamProviderError.reauthorizationRequired(reason: "the session cannot be refreshed")
        }
        do {
            var fresh = try await oauth.refresh(refreshToken: refreshToken, credentials: credentials)
            if fresh.refreshToken == nil {
                fresh.refreshToken = refreshToken
            }
            try keychain.set(fresh, for: Self.tokensAccount)
            cachedTokens = fresh
            return fresh
        } catch let error as StreamProviderError {
            switch error {
            case .oauth(let code, let description):
                // Kick rejected the refresh token itself (for example invalid_grant).
                try? clearTokens()
                throw StreamProviderError.reauthorizationRequired(reason: description ?? code)
            case .httpStatus(let status, _) where status == 400 || status == 401:
                try? clearTokens()
                throw StreamProviderError.reauthorizationRequired(reason: "HTTP \(status) from the token endpoint")
            default:
                throw error
            }
        }
    }

    private func clearTokens() throws {
        cachedTokens = nil
        try keychain.remove(Self.tokensAccount)
    }
}
