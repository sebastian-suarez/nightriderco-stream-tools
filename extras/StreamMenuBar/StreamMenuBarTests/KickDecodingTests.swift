//
//  KickDecodingTests.swift
//  StreamMenuBarTests
//

import Foundation
import Testing
@testable import StreamMenuBar

struct KickDecodingTests {
    @Test func decodesTokenResponseWithNumericExpiry() throws {
        let json = #"{"access_token":"at","token_type":"Bearer","refresh_token":"rt","expires_in":7200,"scope":"user:read channel:read"}"#
        let response = try JSONDecoder().decode(KickTokenResponse.self, from: Data(json.utf8))
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let tokens = response.tokens(issuedAt: issuedAt)
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.scope == "user:read channel:read")
        #expect(tokens.expiresAt == issuedAt.addingTimeInterval(7200))
    }

    @Test func decodesTokenResponseWithStringExpiryAndNoRefreshToken() throws {
        let json = #"{"access_token":"at","expires_in":"3600"}"#
        let response = try JSONDecoder().decode(KickTokenResponse.self, from: Data(json.utf8))
        let tokens = response.tokens(issuedAt: Date(timeIntervalSince1970: 0))
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 3600))
        #expect(tokens.refreshToken == nil)
    }

    @Test func tokensWithoutExpiryNeverCountAsExpiring() {
        let now = Date()
        let expiring = OAuthTokens(accessToken: "at", refreshToken: nil, expiresAt: now.addingTimeInterval(30), scope: nil)
        #expect(expiring.isExpiring(within: 60, now: now))
        #expect(!expiring.isExpiring(within: 10, now: now))
        let unknown = OAuthTokens(accessToken: "at", refreshToken: nil, expiresAt: nil, scope: nil)
        #expect(!unknown.isExpiring(within: 60, now: now))
    }

    @Test func decodesOAuthErrorBody() throws {
        let json = #"{"error":"invalid_grant","error_description":"The refresh token is invalid."}"#
        let body = try JSONDecoder().decode(OAuthErrorResponse.self, from: Data(json.utf8))
        #expect(body.error == "invalid_grant")
        #expect(body.errorDescription == "The refresh token is invalid.")
    }

    @Test func decodesChannelResponse() throws {
        let json = """
        {"data":[{"banner_picture":"https://example.com/b.jpg","broadcaster_user_id":123,\
        "category":{"id":15,"name":"Just Chatting","thumbnail":"https://example.com/c.jpg"},\
        "channel_description":"Hi","slug":"somestreamer",\
        "stream":{"custom_tags":["english"],"is_live":true,"is_mature":false,"key":"k","language":"English",\
        "start_time":"2026-10-13T18:00:00Z","thumbnail":"https://example.com/s.jpg","url":"https://kick.com/somestreamer","viewer_count":1234},\
        "stream_title":"Evening stream","active_subscribers_count":5,"active_gifted_subscribers_count":2,"canceled_subscribers_count":1}],\
        "message":"OK"}
        """
        let response = try JSONDecoder().decode(KickChannelsResponse.self, from: Data(json.utf8))
        let channel = try #require(response.data?.first)
        #expect(channel.slug == "somestreamer")
        #expect(channel.broadcasterUserID == 123)
        #expect(channel.streamTitle == "Evening stream")
        #expect(channel.category?.name == "Just Chatting")
        #expect(channel.stream?.isLive == true)
        #expect(channel.stream?.viewerCount == 1234)
        #expect(channel.stream?.startTime == "2026-10-13T18:00:00Z")
        #expect(channel.activeSubscribersCount == 5)
        #expect(channel.activeGiftedSubscribersCount == 2)
        #expect(channel.canceledSubscribersCount == 1)

        let fetchedAt = Date(timeIntervalSince1970: 1)
        let snapshot = KickStreamProvider.snapshot(from: channel, fetchedAt: fetchedAt)
        #expect(snapshot == StreamSnapshot(channelName: "somestreamer", isLive: true, viewerCount: 1234, fetchedAt: fetchedAt))
    }

    @Test func toleratesSparseChannelResponse() throws {
        let json = #"{"data":[{"slug":"quiet","stream":{"is_live":false,"viewer_count":0,"start_time":""}}]}"#
        let response = try JSONDecoder().decode(KickChannelsResponse.self, from: Data(json.utf8))
        let channel = try #require(response.data?.first)
        let snapshot = KickStreamProvider.snapshot(from: channel, fetchedAt: Date())
        #expect(snapshot.channelName == "quiet")
        #expect(snapshot.isLive == false)
        #expect(snapshot.viewerCount == 0)

        let empty = try JSONDecoder().decode(KickChannelsResponse.self, from: Data(#"{"data":[],"message":""}"#.utf8))
        #expect(empty.data?.isEmpty == true)
    }
}
