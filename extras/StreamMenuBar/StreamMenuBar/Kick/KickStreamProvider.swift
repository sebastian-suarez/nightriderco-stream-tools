//
//  KickStreamProvider.swift
//  StreamMenuBar
//

import Foundation

/// The Kick implementation of `StreamProvider`: one poll is `GET /public/v1/channels` for the
/// signed-in user's own channel. (Followers will come from a separate, unofficial call later.)
nonisolated struct KickStreamProvider: StreamProvider {
    let api: KickAPIClient

    func fetchSnapshot() async throws -> StreamSnapshot {
        let response: KickChannelsResponse = try await api.get("channels")
        guard let channel = response.data?.first else {
            throw StreamProviderError.invalidResponse("Kick returned no channel for the signed-in user.")
        }
        return Self.snapshot(from: channel, fetchedAt: Date())
    }

    static func snapshot(from channel: KickChannel, fetchedAt: Date) -> StreamSnapshot {
        StreamSnapshot(
            channelName: channel.slug,
            isLive: channel.stream?.isLive,
            viewerCount: channel.stream?.viewerCount,
            fetchedAt: fetchedAt
        )
    }
}
