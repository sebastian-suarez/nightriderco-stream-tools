//
//  KickAPIClient.swift
//  StreamMenuBar
//

import Foundation
import os

/// Authenticated calls to the official API at api.kick.com/public/v1. Runs off the main actor.
nonisolated struct KickAPIClient: Sendable {
    static let baseURL = URL(string: "https://api.kick.com/public/v1/")!

    let auth: KickAuthSession
    var session: URLSession = .shared

    /// GET `path` with the user's token. On 401 the token is refreshed and the call retried once.
    /// A second 401 asks the UI for a new sign-in but keeps the tokens: a refresh that succeeds
    /// while the API refuses the token is not a revoked session, and signing in again replaces them.
    @concurrent
    func get<Response: Decodable & Sendable>(_ path: String) async throws -> Response {
        let token = try await auth.validAccessToken()
        var (data, status) = try await perform(path, bearer: token)
        if status == 401 {
            Log.auth.notice("GET \(path, privacy: .public) returned 401: \(KickOAuthClient.excerpt(data), privacy: .public); refreshing the token")
            await logIntrospection(of: token)
            let refreshed = try await auth.refreshTokens()
            (data, status) = try await perform(path, bearer: refreshed.accessToken)
            if status == 401 {
                Log.auth.error("GET \(path, privacy: .public) returned 401 again with a fresh token: \(KickOAuthClient.excerpt(data), privacy: .public)")
                await logIntrospection(of: refreshed.accessToken)
                throw StreamProviderError.reauthorizationRequired(reason: "Kick rejected the access token: \(KickOAuthClient.excerpt(data))")
            }
        }
        guard (200..<300).contains(status) else {
            throw StreamProviderError.httpStatus(status, body: KickOAuthClient.excerpt(data))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw StreamProviderError.invalidResponse("\(path): \(error.localizedDescription)")
        }
    }

    /// Logs what Kick itself says about a token the API just refused (active, scope, client).
    private func logIntrospection(of token: String) async {
        do {
            let result = try await KickOAuthClient(session: session).introspect(accessToken: token)
            Log.auth.notice("Token introspection: HTTP \(result.status) \(result.body, privacy: .public)")
        } catch {
            Log.auth.notice("Token introspection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func perform(_ path: String, bearer token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamProviderError.invalidResponse("Not an HTTP response")
        }
        Log.poll.debug("GET \(path, privacy: .public) -> \(http.statusCode)")
        return (data, http.statusCode)
    }
}

// MARK: - Response models (docs.kick.com/apis/channels)

nonisolated struct KickChannelsResponse: Decodable, Sendable {
    var data: [KickChannel]?
    var message: String?
}

nonisolated struct KickChannel: Decodable, Sendable, Equatable {
    var slug: String?
    var broadcasterUserID: Int?
    var streamTitle: String?
    var category: Category?
    var stream: Stream?
    var activeSubscribersCount: Int?
    var activeGiftedSubscribersCount: Int?
    var canceledSubscribersCount: Int?

    nonisolated struct Category: Decodable, Sendable, Equatable {
        var id: Int?
        var name: String?
    }

    nonisolated struct Stream: Decodable, Sendable, Equatable {
        var isLive: Bool?
        var viewerCount: Int?
        /// ISO 8601 text as Kick sends it; parsed only where uptime is needed.
        var startTime: String?

        private enum CodingKeys: String, CodingKey {
            case isLive = "is_live"
            case viewerCount = "viewer_count"
            case startTime = "start_time"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case slug
        case broadcasterUserID = "broadcaster_user_id"
        case streamTitle = "stream_title"
        case category
        case stream
        case activeSubscribersCount = "active_subscribers_count"
        case activeGiftedSubscribersCount = "active_gifted_subscribers_count"
        case canceledSubscribersCount = "canceled_subscribers_count"
    }
}
