//
//  OBSEncoderProvider.swift
//  StreamMenuBar
//

import Foundation

/// The OBS implementation of `EncoderProvider`: one poll is `GetStreamStatus`, and the bitrate
/// is the growth of `outputBytes` between two polls over a monotonic clock, the way OBS's own
/// status bar computes it. (`outputDuration` is frame-derived, so it under-counts during
/// encoder stalls and is not used.)
actor OBSEncoderProvider: EncoderProvider {
    nonisolated struct Sample: Sendable, Equatable {
        var bytes: Int64
        var takenAt: ContinuousClock.Instant
        /// `OBSWebSocketClient.epoch` when the sample was taken. A different value means a new
        /// connection or a stream restart, so the two samples are not comparable.
        var epoch: Int
    }

    private let client: OBSWebSocketClient
    private let clock = ContinuousClock()
    private var previous: Sample?

    init(configuration: OBSWebSocketClient.Configuration, session: URLSession = .shared) {
        client = OBSWebSocketClient(configuration: configuration, session: session)
    }

    func fetchStatus() async throws -> EncoderStatus {
        let reply: OBSReply<OBSStreamStatus>
        do {
            reply = try await client.request("GetStreamStatus")
        } catch {
            previous = nil
            throw error
        }
        let fetchedAt = Date()
        guard reply.data.outputActive else {
            previous = nil
            return EncoderStatus(isStreaming: false, bitrateKbps: nil, fetchedAt: fetchedAt)
        }
        let sample = Sample(bytes: reply.data.outputBytes, takenAt: clock.now, epoch: reply.epoch)
        let bitrate = Self.bitrateKbps(from: previous, to: sample)
        previous = sample
        return EncoderStatus(isStreaming: true, bitrateKbps: bitrate, fetchedAt: fetchedAt)
    }

    func disconnect() async {
        previous = nil
        await client.disconnect()
    }

    /// nil when there is no comparable earlier sample (none yet, another epoch, counters that went
    /// backwards, or no time elapsed). Unchanged counters are a real 0 kb/s.
    nonisolated static func bitrateKbps(from previous: Sample?, to current: Sample) -> Int? {
        guard let previous, previous.epoch == current.epoch, current.bytes >= previous.bytes else { return nil }
        let elapsed = previous.takenAt.duration(to: current.takenAt)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        let kbps = Double(current.bytes - previous.bytes) * 8 / seconds / 1000
        guard kbps.isFinite else { return nil }
        return Int(kbps.rounded())
    }
}
