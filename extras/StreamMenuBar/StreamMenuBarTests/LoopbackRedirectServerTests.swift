//
//  LoopbackRedirectServerTests.swift
//  StreamMenuBarTests
//
//  Each test uses its own port, away from the app's 8732, so they can run in parallel and
//  while the app itself is signing in.
//

import Foundation
import Testing
@testable import StreamMenuBar

struct LoopbackRedirectServerTests {
    private func callbackURL(port: UInt16, query: String) -> URL {
        URL(string: "http://localhost:\(port)/callback?\(query)")!
    }

    @Test func deliversCodeFromMatchingCallback() async throws {
        let server = try await LoopbackRedirectServer.start(port: 8741, expectedState: "s1")
        async let code = server.waitForCode(timeout: .seconds(10))
        let (body, response) = try await URLSession.shared.data(from: callbackURL(port: 8741, query: "code=abc123&state=s1"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Signed in"))
        #expect(try await code == "abc123")
    }

    @Test func rejectsMismatchedState() async throws {
        let server = try await LoopbackRedirectServer.start(port: 8742, expectedState: "expected")
        let waiting = Task { try await server.waitForCode(timeout: .seconds(10)) }
        let (_, response) = try await URLSession.shared.data(from: callbackURL(port: 8742, query: "code=abc123&state=other"))
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        await #expect(throws: StreamProviderError.stateMismatch) {
            try await waiting.value
        }
    }

    @Test func reportsDeniedAuthorization() async throws {
        let server = try await LoopbackRedirectServer.start(port: 8743, expectedState: "s1")
        let waiting = Task { try await server.waitForCode(timeout: .seconds(10)) }
        let (_, response) = try await URLSession.shared.data(
            from: callbackURL(port: 8743, query: "error=access_denied&error_description=User%20declined&state=s1"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        await #expect(throws: StreamProviderError.authorizationDenied("User declined")) {
            try await waiting.value
        }
    }

    @Test func ignoresOtherPathsUntilTheCallbackArrives() async throws {
        let server = try await LoopbackRedirectServer.start(port: 8744, expectedState: "s1")
        async let code = server.waitForCode(timeout: .seconds(10))
        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "http://localhost:8744/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)
        _ = try await URLSession.shared.data(from: callbackURL(port: 8744, query: "code=later&state=s1"))
        #expect(try await code == "later")
    }

    @Test func timesOutWithoutCallback() async throws {
        let server = try await LoopbackRedirectServer.start(port: 8745, expectedState: "s1")
        await #expect(throws: StreamProviderError.signInTimedOut) {
            try await server.waitForCode(timeout: .milliseconds(200))
        }
    }

    @Test func stopCancelsWaiting() async throws {
        let server = try await LoopbackRedirectServer.start(port: 8746, expectedState: "s1")
        let waiting = Task { try await server.waitForCode(timeout: .seconds(10)) }
        server.stop()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
    }

    @Test func portCanBeReusedAfterStop() async throws {
        let first = try await LoopbackRedirectServer.start(port: 8747, expectedState: "s1")
        first.stop()
        let second = try await LoopbackRedirectServer.start(port: 8747, expectedState: "s2")
        async let code = second.waitForCode(timeout: .seconds(10))
        _ = try await URLSession.shared.data(from: callbackURL(port: 8747, query: "code=again&state=s2"))
        #expect(try await code == "again")
    }
}
