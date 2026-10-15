//
//  OBSWebSocketClientTests.swift
//  StreamMenuBarTests
//
//  Each test uses its own loopback port (8751-8760), away from the app's 8732 and OBS's 4455.
//

import Foundation
import Testing
@testable import StreamMenuBar

@Suite(.timeLimit(.minutes(1)))
struct OBSWebSocketClientTests {
    private func client(port: UInt16, password: String? = nil, timeout: Duration = .seconds(5)) -> OBSWebSocketClient {
        OBSWebSocketClient(configuration: .init(port: port, password: { password }, timeout: timeout))
    }

    private static let streaming: FakeOBSServer.RequestHandler = { _ in
        (["result": true, "code": 100], ["outputActive": true, "outputBytes": 1_000_000, "outputDuration": 1000, "outputReconnecting": false])
    }

    @Test func identifiesWithPasswordAndReusesTheConnection() async throws {
        let server = try await FakeOBSServer.start(port: 8751, .init(password: "hunter2", handler: Self.streaming))
        defer { server.stop() }
        let client = client(port: 8751, password: "hunter2")
        let first: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
        #expect(first.data == OBSStreamStatus(outputActive: true, outputReconnecting: false, outputBytes: 1_000_000, outputDuration: 1000))
        let second: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
        #expect(second.epoch == first.epoch)
        #expect(server.identifiedCount == 1)
        #expect(await client.isConnected)
    }

    @Test func connectsWithoutPasswordWhenTheServerNeedsNone() async throws {
        let server = try await FakeOBSServer.start(port: 8752)
        defer { server.stop() }
        let reply: OBSReply<OBSStreamStatus> = try await client(port: 8752).request("GetStreamStatus")
        #expect(reply.data.outputActive == false)
    }

    @Test func wrongPasswordIsAuthenticationFailed() async throws {
        let server = try await FakeOBSServer.start(port: 8753, .init(password: "hunter2"))
        defer { server.stop() }
        let wrong = client(port: 8753, password: "nope")
        await #expect(throws: EncoderError.authenticationFailed) {
            let _: OBSReply<OBSStreamStatus> = try await wrong.request("GetStreamStatus")
        }
        let missing = client(port: 8753, password: nil)
        await #expect(throws: EncoderError.authenticationFailed) {
            let _: OBSReply<OBSStreamStatus> = try await missing.request("GetStreamStatus")
        }
        #expect(await !wrong.isConnected)
    }

    @Test func refusedPortIsUnavailable() async throws {
        let client = client(port: 8754)
        do {
            let _: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
            Issue.record("expected a failure")
        } catch EncoderError.unavailable {
        }
    }

    @Test func reconnectsAfterTheServerDropsTheSocket() async throws {
        let server = try await FakeOBSServer.start(port: 8755, .init(handler: Self.streaming))
        defer { server.stop() }
        let client = client(port: 8755)
        let before: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
        server.dropConnections()
        for _ in 0..<50 where await client.isConnected {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await !client.isConnected)
        let after: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
        #expect(after.epoch > before.epoch)
        #expect(server.identifiedCount == 2)
    }

    @Test func silentServerTimesOutTheHandshake() async throws {
        let server = try await FakeOBSServer.start(port: 8756, .init(silent: true))
        defer { server.stop() }
        let client = client(port: 8756, timeout: .milliseconds(300))
        do {
            let _: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
            Issue.record("expected a timeout")
        } catch EncoderError.timedOut {
        }
        #expect(await !client.isConnected)
    }

    @Test func unansweredRequestTimesOutAndDropsTheConnection() async throws {
        let server = try await FakeOBSServer.start(port: 8757, .init(answersRequests: false))
        defer { server.stop() }
        let client = client(port: 8757, timeout: .milliseconds(300))
        do {
            let _: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
            Issue.record("expected a timeout")
        } catch EncoderError.timedOut {
        }
        // The handshake went through, so it was the request deadline that fired.
        #expect(server.identifiedCount == 1)
        #expect(await !client.isConnected)
    }

    @Test func streamStateChangeAdvancesTheEpoch() async throws {
        let server = try await FakeOBSServer.start(port: 8758, .init(handler: Self.streaming))
        defer { server.stop() }
        let client = client(port: 8758)
        let before: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
        server.sendEvent(type: "StreamStateChanged", data: ["outputActive": false, "outputState": "OBS_WEBSOCKET_OUTPUT_STOPPED"])
        var after = before
        for _ in 0..<50 where after.epoch == before.epoch {
            try await Task.sleep(for: .milliseconds(50))
            after = try await client.request("GetStreamStatus")
        }
        #expect(after.epoch == before.epoch + 1)
        #expect(await client.isConnected)
    }

    @Test func failedRequestStatusIsSurfaced() async throws {
        let server = try await FakeOBSServer.start(port: 8759, .init(handler: { _ in
            (["result": false, "code": 204, "comment": "Your request type is not valid."], nil)
        }))
        defer { server.stop() }
        await #expect(throws: EncoderError.requestFailed(code: 204, comment: "Your request type is not valid.")) {
            let _: OBSReply<OBSStreamStatus> = try await client(port: 8759).request("NoSuchRequest")
        }
    }

    @Test func socketClosedRightAfterIdentifyFailsTheRequestInsteadOfHanging() async throws {
        let server = try await FakeOBSServer.start(port: 8762, .init(closesAfterIdentify: true))
        defer { server.stop() }
        let client = client(port: 8762, timeout: .seconds(2))
        for _ in 0..<3 {
            do {
                let _: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
                Issue.record("expected a failure")
            } catch is EncoderError {
            }
        }
        #expect(server.identifiedCount >= 1)
        #expect(await !client.isConnected)
    }

    @Test func epochIsTheOneTheResponseArrivedIn() async throws {
        let server = try await FakeOBSServer.start(port: 8763, .init(eventsAfterResponse: ["StreamStateChanged"], handler: Self.streaming))
        defer { server.stop() }
        let client = client(port: 8763)
        var epochs: [Int] = []
        for _ in 0..<5 {
            let reply: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
            epochs.append(reply.epoch)
            // Let the event queued behind the response be processed before the next request.
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(epochs == epochs.sorted())
        #expect(Set(epochs).count == epochs.count, "every reply was tagged with the epoch before its trailing event")
    }

    @Test func disconnectFailsWaitingRequestsAndClosesTheSocket() async throws {
        let server = try await FakeOBSServer.start(port: 8760, .init(answersRequests: false))
        defer { server.stop() }
        let client = client(port: 8760)
        let waiting = Task {
            let _: OBSReply<OBSStreamStatus> = try await client.request("GetStreamStatus")
        }
        for _ in 0..<50 where await !client.isConnected {
            try await Task.sleep(for: .milliseconds(50))
        }
        await client.disconnect()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(await !client.isConnected)
    }
}
