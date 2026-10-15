//
//  LoopbackRedirectServer.swift
//  StreamMenuBar
//

import Foundation
import Network
import os
import Synchronization

/// Receives the OAuth redirect once on http://localhost:<port>/callback.
///
/// Bound to the loopback interface only, so nothing outside this Mac can reach it. The first
/// request to the callback path settles the outcome (code, denial, or state mismatch), answers
/// the browser with a small HTML page, and stops the listener. Other paths get a 404 so a
/// browser's favicon request cannot consume the callback.
nonisolated final class LoopbackRedirectServer: @unchecked Sendable {
    // @unchecked: NWListener is not Sendable but serializes its work on `queue`;
    // every other mutable value lives behind `state`.

    private struct State {
        var ready: CheckedContinuation<Void, any Error>?
        var callback: CheckedContinuation<String, any Error>?
        /// Set when the outcome arrives before anyone awaits it.
        var pendingResult: Result<String, any Error>?
        var isFinished = false
    }

    let port: UInt16
    private let expectedState: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.sebastiansuarez.StreamMenuBar.oauth-redirect")
    private let state = Mutex(State())

    private init(listener: NWListener, port: UInt16, expectedState: String) {
        self.listener = listener
        self.port = port
        self.expectedState = expectedState
    }

    /// Binds the port and returns once the listener accepts connections.
    ///
    /// `NWListener.cancel()` releases a port asynchronously, so a retry right after a cancelled
    /// sign-in can find it still taken; the bind is retried for about a second before giving up.
    static func start(port: UInt16, expectedState: String) async throws -> LoopbackRedirectServer {
        var attempt = 0
        while true {
            do {
                return try await bind(port: port, expectedState: expectedState)
            } catch StreamProviderError.redirectPortUnavailable where attempt < 5 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private static func bind(port: UInt16, expectedState: String) async throws -> LoopbackRedirectServer {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw StreamProviderError.redirectPortUnavailable(port)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // Lets a sign-in retry bind the port while the previous attempt's connection is in TIME_WAIT.
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            throw StreamProviderError.redirectPortUnavailable(port)
        }
        let server = LoopbackRedirectServer(listener: listener, port: port, expectedState: expectedState)
        try await server.waitUntilReady()
        return server
    }

    /// Waits for the redirect and returns the authorization code.
    func waitForCode(timeout: Duration) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitCallback() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw StreamProviderError.signInTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Stops listening. A pending `waitForCode` throws `CancellationError`.
    func stop() {
        finish(.failure(CancellationError()))
    }

    // MARK: - Lifecycle

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { $0.ready = continuation }
            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    Log.redirect.info("Listening on localhost:\(self.port)")
                    self.resumeReady(.success(()))
                case .waiting(let error), .failed(let error):
                    // Loopback has nothing to wait for: either state means the port could not be bound.
                    Log.redirect.error("Listener on port \(self.port) failed: \(String(describing: error), privacy: .public)")
                    self.resumeReady(.failure(StreamProviderError.redirectPortUnavailable(self.port)))
                    self.finish(.failure(error))
                case .cancelled:
                    self.resumeReady(.failure(CancellationError()))
                    self.finish(.failure(CancellationError()))
                case .setup:
                    break
                @unknown default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                connection.start(queue: self.queue)
                self.receive(on: connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func resumeReady(_ result: Result<Void, any Error>) {
        let continuation = state.withLock { locked -> CheckedContinuation<Void, any Error>? in
            defer { locked.ready = nil }
            return locked.ready
        }
        continuation?.resume(with: result)
    }

    private func awaitCallback() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                let immediate = state.withLock { locked -> Result<String, any Error>? in
                    if let pending = locked.pendingResult {
                        locked.pendingResult = nil
                        return pending
                    }
                    if locked.isFinished {
                        return .failure(CancellationError())
                    }
                    locked.callback = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Settles the outcome exactly once and stops the listener.
    private func finish(_ result: Result<String, any Error>) {
        let (isFirst, continuation) = state.withLock { locked -> (Bool, CheckedContinuation<String, any Error>?) in
            guard !locked.isFinished else { return (false, nil) }
            locked.isFinished = true
            if let waiting = locked.callback {
                locked.callback = nil
                return (true, waiting)
            }
            locked.pendingResult = result
            return (true, nil)
        }
        guard isFirst else { return }
        listener.cancel()
        continuation?.resume(with: result)
    }

    // MARK: - HTTP

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maximumRequestSize = 64 * 1024

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = buffered
            if let content {
                request.append(content)
            }
            let hasHeaders = request.range(of: Self.headerTerminator) != nil
            if !hasHeaders, error == nil, !isComplete, request.count < Self.maximumRequestSize {
                self.receive(on: connection, buffered: request)
                return
            }
            self.handle(request: request, on: connection)
        }
    }

    private func handle(request: Data, on connection: NWConnection) {
        let text = String(decoding: request, as: UTF8.self)
        let requestLine = text.prefix { $0 != "\r" && $0 != "\n" }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://localhost\(parts[1])") else {
            respond(on: connection, status: "400 Bad Request", title: "Bad request",
                    message: "This address only accepts the Kick sign-in redirect.")
            return
        }
        guard components.path == KickOAuth.redirectPath else {
            Log.redirect.notice("Ignoring request for \(components.path, privacy: .public)")
            respond(on: connection, status: "404 Not Found", title: "Not found",
                    message: "This address only accepts the Kick sign-in redirect.")
            return
        }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }

        let outcome: Result<String, any Error>
        let status: String
        let title: String
        let message: String
        if let error = value("error") {
            let detail = value("error_description") ?? error
            outcome = .failure(StreamProviderError.authorizationDenied(detail))
            status = "200 OK"
            title = "Sign-in not completed"
            message = "Kick reported: \(detail). You can close this tab."
        } else if value("state") != expectedState {
            outcome = .failure(StreamProviderError.stateMismatch)
            status = "400 Bad Request"
            title = "Sign-in rejected"
            message = "This response does not belong to the current sign-in attempt. Start the sign-in again from Stream menu bar."
        } else if let code = value("code"), !code.isEmpty {
            outcome = .success(code)
            status = "200 OK"
            title = "Signed in"
            message = "You can close this tab and return to Stream menu bar."
        } else {
            outcome = .failure(StreamProviderError.invalidResponse("The redirect did not include an authorization code."))
            status = "400 Bad Request"
            title = "Sign-in failed"
            message = "The redirect did not include an authorization code."
        }
        Log.redirect.info("Callback received: \(title, privacy: .public)")
        // Finish only after the browser has its page, so the listener outlives the response.
        respond(on: connection, status: status, title: title, message: message) { [weak self] in
            self?.finish(outcome)
        }
    }

    private func respond(on connection: NWConnection, status: String, title: String, message: String,
                         completion: (@Sendable () -> Void)? = nil) {
        let body = Data(Self.page(title: title, message: message).utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px/1.5 -apple-system,system-ui,sans-serif;background:#f5f5f7;color:#1d1d1f}
        main{max-width:28rem;padding:2rem;text-align:center}h1{font-size:1.5rem;margin:0 0 .5rem}
        @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}}
        </style></head>
        <body><main><h1>\(escape(title))</h1><p>\(escape(message))</p></main></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
