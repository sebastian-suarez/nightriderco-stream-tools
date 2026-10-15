//
//  OBSEncoderProviderTests.swift
//  StreamMenuBarTests
//

import Foundation
import Synchronization
import Testing
@testable import StreamMenuBar

@Suite(.timeLimit(.minutes(1)))
struct OBSEncoderProviderTests {
    private typealias Sample = OBSEncoderProvider.Sample
    private let start = ContinuousClock.Instant.now

    @Test func bitrateIsBytesGrownOverElapsedTime() {
        let previous = Sample(bytes: 1_000_000, takenAt: start, epoch: 1)
        let current = Sample(bytes: 2_000_000, takenAt: start + .seconds(1), epoch: 1)
        #expect(OBSEncoderProvider.bitrateKbps(from: previous, to: current) == 8000)
        let later = Sample(bytes: 2_005_000, takenAt: start + .milliseconds(5000), epoch: 1)
        #expect(OBSEncoderProvider.bitrateKbps(from: previous, to: later) == 1608)
    }

    @Test func noBitrateWithoutAComparableSample() {
        let previous = Sample(bytes: 1_000_000, takenAt: start, epoch: 1)
        let current = Sample(bytes: 2_000_000, takenAt: start + .seconds(1), epoch: 1)
        #expect(OBSEncoderProvider.bitrateKbps(from: nil, to: current) == nil)
        // Another connection or a stream restart.
        #expect(OBSEncoderProvider.bitrateKbps(from: previous, to: Sample(bytes: 8_000_000, takenAt: start + .seconds(4), epoch: 2)) == nil)
        // Counters went backwards.
        #expect(OBSEncoderProvider.bitrateKbps(from: previous, to: Sample(bytes: 500, takenAt: start + .seconds(1), epoch: 1)) == nil)
        // No time elapsed.
        #expect(OBSEncoderProvider.bitrateKbps(from: previous, to: Sample(bytes: 2_000_000, takenAt: start, epoch: 1)) == nil)
    }

    @Test func frozenCountersAreZeroNotNil() {
        let previous = Sample(bytes: 1_000_000, takenAt: start, epoch: 1)
        let current = Sample(bytes: 1_000_000, takenAt: start + .seconds(5), epoch: 1)
        #expect(OBSEncoderProvider.bitrateKbps(from: previous, to: current) == 0)
    }

    @Test func secondPollReportsTheBitrateAndStoppingClearsIt() async throws {
        let bytes = Counter()
        let server = try await FakeOBSServer.start(port: 8761, .init(handler: { _ in
            let value = bytes.next()
            return (["result": true, "code": 100], ["outputActive": value < 3_000_000, "outputBytes": value])
        }))
        defer { server.stop() }
        let provider = OBSEncoderProvider(configuration: .init(port: 8761))

        let first = try await provider.fetchStatus()
        #expect(first.isStreaming)
        #expect(first.bitrateKbps == nil)
        try await Task.sleep(for: .milliseconds(200))
        let second = try await provider.fetchStatus()
        #expect(second.isStreaming)
        let kbps = try #require(second.bitrateKbps)
        // 1,000,000 bytes in at least 0.2 s: at most 40,000 kb/s, and plenty on a slow run.
        #expect(kbps > 1_000 && kbps < 40_500)
        let stopped = try await provider.fetchStatus()
        #expect(stopped == EncoderStatus(isStreaming: false, bitrateKbps: nil, fetchedAt: stopped.fetchedAt))
        await provider.disconnect()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OBSEncoderProviderRestartTests {
    @Test func aStreamRestartBetweenPollsNeverYieldsABitrate() async throws {
        // Every response is followed by a StreamStateChanged, so no two samples share a stream.
        let bytes = Counter()
        let server = try await FakeOBSServer.start(port: 8764, .init(eventsAfterResponse: ["StreamStateChanged"], handler: { _ in
            (["result": true, "code": 100], ["outputActive": true, "outputBytes": bytes.next()])
        }))
        defer { server.stop() }
        let provider = OBSEncoderProvider(configuration: .init(port: 8764))
        for _ in 0..<5 {
            let status = try await provider.fetchStatus()
            #expect(status.isStreaming)
            #expect(status.bitrateKbps == nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        await provider.disconnect()
    }
}

/// 1,000,000 bytes more per call.
private final class Counter: Sendable {
    private let value = Mutex<Int64>(0)
    func next() -> Int64 {
        value.withLock { locked in
            locked += 1_000_000
            return locked
        }
    }
}
