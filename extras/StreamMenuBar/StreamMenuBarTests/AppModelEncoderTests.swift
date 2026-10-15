//
//  AppModelEncoderTests.swift
//  StreamMenuBarTests
//

import Foundation
import Synchronization
import Testing
@testable import StreamMenuBar

/// A provider whose fetch waits until the test releases it.
private final class GatedEncoderProvider: EncoderProvider, Sendable {
    private struct State {
        /// The suspended fetch.
        var gate: CheckedContinuation<Void, Never>?
        /// A test waiting for the fetch to start.
        var waiting: CheckedContinuation<Void, Never>?
    }

    let status: EncoderStatus
    private let state = Mutex(State())

    init(bitrateKbps: Int) {
        status = EncoderStatus(isStreaming: true, bitrateKbps: bitrateKbps, fetchedAt: Date())
    }

    func fetchStatus() async throws -> EncoderStatus {
        await withCheckedContinuation { continuation in
            let waiting = state.withLock { locked -> CheckedContinuation<Void, Never>? in
                locked.gate = continuation
                defer { locked.waiting = nil }
                return locked.waiting
            }
            waiting?.resume()
        }
        return status
    }

    func disconnect() async {}

    /// Returns once `fetchStatus` is suspended.
    func waitUntilFetching() async {
        await withCheckedContinuation { continuation in
            let alreadyFetching = state.withLock { locked -> Bool in
                if locked.gate != nil { return true }
                locked.waiting = continuation
                return false
            }
            if alreadyFetching {
                continuation.resume()
            }
        }
    }

    func release() {
        let gate = state.withLock { locked -> CheckedContinuation<Void, Never>? in
            defer { locked.gate = nil }
            return locked.gate
        }
        gate?.resume()
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppModelEncoderTests {
    @Test func aFetchFromReplacedSettingsDoesNotPublish() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Preferences.obsEnabledKey)
        defaults.set(true, forKey: Preferences.obsEnabledKey)
        defer { defaults.set(previous, forKey: Preferences.obsEnabledKey) }

        let providers = Mutex<[GatedEncoderProvider]>([])
        let model = AppModel(keychain: KeychainStore(service: "dev.sebastiansuarez.StreamMenuBar.tests")) { _ in
            let provider = GatedEncoderProvider(bitrateKbps: providers.withLock { $0.count + 1 } * 1000)
            providers.withLock { $0.append(provider) }
            return provider
        }
        model.encoderSettingsChanged()
        let first = try #require(providers.withLock { $0.first })
        await first.waitUntilFetching()
        #expect(model.encoderState == .connecting)

        model.encoderSettingsChanged()
        let second = try #require(providers.withLock { $0.last })
        #expect(providers.withLock { $0.count } == 2)
        await second.waitUntilFetching()

        // The old provider answers late: its 1000 kb/s must not replace the new loop's state.
        first.release()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.encoderState == .connecting)

        second.release()
        for _ in 0..<50 where model.encoderState == .connecting {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.encoderStatus?.bitrateKbps == 2000)

        defaults.set(false, forKey: Preferences.obsEnabledKey)
        model.encoderSettingsChanged()
        #expect(model.encoderState == .disabled)
    }
}
