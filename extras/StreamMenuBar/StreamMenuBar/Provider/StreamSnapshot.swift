//
//  StreamSnapshot.swift
//  StreamMenuBar
//

import Foundation

/// One reading of the signed-in user's own stream, taken at `fetchedAt`.
/// A value that could not be fetched is nil and shows as unavailable in the UI.
nonisolated struct StreamSnapshot: Sendable, Equatable {
    /// The channel's public name (Kick calls it the slug).
    var channelName: String?
    var isLive: Bool?
    var viewerCount: Int?
    var fetchedAt: Date
}

/// A platform-neutral source of stream metrics. Kick is the only implementation for now;
/// UI code depends on this protocol and `StreamSnapshot` only.
nonisolated protocol StreamProvider: Sendable {
    /// Fetches the current values. Throws a `StreamProviderError` auth case when the user
    /// has to sign in (again); any other error is transient and the caller retries later.
    func fetchSnapshot() async throws -> StreamSnapshot
}
