//
//  OBSWebSocketClient.swift
//  StreamMenuBar
//

import Foundation
import os

/// A client for obs-websocket 5 (the server built into OBS Studio 28 and later).
///
/// Connects on the first request, identifies (with the password when OBS requires one; close
/// code 4009 means it was rejected), subscribes to output events only, and keeps the socket open
/// between requests. Every wait has a deadline. Any failure drops the socket and fails the
/// requests waiting on it, and the next request reconnects. Loopback only: OBS on another
/// machine would need App Transport Security and local-network permission work.
actor OBSWebSocketClient {
    nonisolated struct Configuration: Sendable {
        var port: UInt16 = 4455
        /// Read when connecting, so a password saved in Settings applies to the next connection.
        var password: @Sendable () throws -> String? = { nil }
        /// Longest wait for the handshake and for each request.
        var timeout: Duration = .seconds(5)

        var url: URL { URL(string: "ws://localhost:\(port)")! }
    }

    static let subprotocol = "obswebsocket.json"
    static let rpcVersion = 1
    /// EventSubscription::Outputs (1 << 6): stream start/stop, used to reset the bitrate baseline.
    static let eventSubscriptions = 1 << 6
    static let authenticationFailedCloseCode = 4009

    private struct Connection {
        let id: Int
        let task: URLSessionWebSocketTask
        var receiver: Task<Void, Never>?
    }

    let configuration: Configuration
    private let session: URLSession
    private var connection: Connection?
    private var connecting: Task<Connection, any Error>?
    /// Waiting requests, resumed with the response bytes and the epoch at the moment they arrived.
    private var pending: [String: CheckedContinuation<(Data, Int), any Error>] = [:]
    private var connectionCounter = 0
    private var requestCounter = 0
    /// Changes on every newly identified connection and on every StreamStateChanged event, so a
    /// caller can tell whether two readings belong to the same stream output.
    private(set) var epoch = 0

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    var isConnected: Bool { connection != nil }

    /// Sends `requestType` and returns its `responseData`, connecting first when needed.
    func request<Response: Decodable & Sendable>(_ requestType: String) async throws -> OBSReply<Response> {
        let connection = try await connectIfNeeded()
        // The socket can have been dropped while this call was suspended on the handshake.
        guard self.connection?.id == connection.id else {
            throw EncoderError.unavailable("the connection to OBS closed before the request was sent")
        }
        requestCounter += 1
        let id = "r\(requestCounter)"
        let message = try Self.encode(OBSMessage(op: 6, d: OBSRequest(requestType: requestType, requestId: id)))
        let deadline = Task { [timeout = configuration.timeout] in
            try await Task.sleep(for: timeout)
            await self.timeOut(id, connectionID: connection.id, requestType: requestType)
        }
        defer { deadline.cancel() }
        let (data, epoch) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), any Error>) in
                // Registered before sending, so a fast answer cannot arrive before anyone waits for it.
                pending[id] = continuation
                connection.task.send(message) { error in
                    guard let error else { return }
                    let mapped = Self.map(error, closeCode: connection.task.closeCode)
                    Task {
                        await self.drop(connection.id, error: mapped)
                        await self.settle(id, with: .failure(mapped))
                    }
                }
            }
        } onCancel: {
            Task { await self.settle(id, with: .failure(CancellationError())) }
        }
        let response = try Self.decode(OBSMessage<OBSRequestResponse<Response>>.self, from: data)
        guard response.d.requestStatus.result else {
            throw EncoderError.requestFailed(code: response.d.requestStatus.code, comment: response.d.requestStatus.comment)
        }
        guard let responseData = response.d.responseData else {
            throw EncoderError.protocolError("\(requestType) returned no data")
        }
        return OBSReply(data: responseData, epoch: epoch)
    }

    /// Closes the socket. Requests waiting on it throw `CancellationError`.
    func disconnect() {
        connecting?.cancel()
        if let connection {
            drop(connection.id, error: CancellationError())
        }
    }

    // MARK: - Connection

    private func connectIfNeeded() async throws -> Connection {
        if let connection { return connection }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        return try await task.value
    }

    private func connect() async throws -> Connection {
        // Cleared here, on the actor, before anyone awaiting the task resumes, so a request that
        // arrives after a failed attempt starts a fresh one instead of inheriting the stale error.
        defer { connecting = nil }
        let task = session.webSocketTask(with: configuration.url, protocols: [Self.subprotocol])
        task.resume()
        Log.obs.debug("Connecting to port \(self.configuration.port)")
        do {
            try await Self.withDeadline(configuration.timeout, "OBS did not complete the handshake") { [password = configuration.password] in
                try await Self.handshake(task, password: password)
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            let mapped = Self.map(error, closeCode: task.closeCode)
            Log.obs.notice("Connection failed: \(mapped.localizedDescription, privacy: .public)")
            throw mapped
        }
        // `disconnect()` during the handshake cancels this task; the handshake may already have finished.
        if Task.isCancelled {
            task.cancel(with: .goingAway, reason: nil)
            throw CancellationError()
        }
        connectionCounter += 1
        epoch += 1
        let id = connectionCounter
        var connection = Connection(id: id, task: task, receiver: nil)
        connection.receiver = Task { await self.receiveLoop(connectionID: id, task: task) }
        self.connection = connection
        Log.obs.info("Connected to OBS on port \(self.configuration.port)")
        return connection
    }

    /// `URLSessionWebSocketTask.receive()` ignores task cancellation, so the deadline cancels the
    /// socket itself to make the pending receive fail.
    private nonisolated static func handshake(_ task: URLSessionWebSocketTask, password: @Sendable () throws -> String?) async throws {
        try await withTaskCancellationHandler {
            let hello = try await receive(OBSMessage<OBSHello>.self, from: task, expectingOp: 0)
            guard hello.d.rpcVersion >= rpcVersion else {
                throw EncoderError.protocolError("obs-websocket RPC version \(hello.d.rpcVersion) is too old")
            }
            var identify = OBSIdentify(rpcVersion: rpcVersion, authentication: nil, eventSubscriptions: eventSubscriptions)
            if let challenge = hello.d.authentication {
                guard let password = try password(), !password.isEmpty else {
                    throw EncoderError.authenticationFailed
                }
                identify.authentication = OBSAuthentication.response(password: password, salt: challenge.salt, challenge: challenge.challenge)
            }
            try await task.send(try encode(OBSMessage(op: 1, d: identify)))
            _ = try await receive(OBSMessage<OBSIdentified>.self, from: task, expectingOp: 2)
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func receiveLoop(connectionID: Int, task: URLSessionWebSocketTask) async {
        while connection?.id == connectionID {
            do {
                let message = try await task.receive()
                handle(message)
            } catch {
                guard connection?.id == connectionID else { return }
                let mapped = Self.map(error, closeCode: task.closeCode)
                Log.obs.notice("Connection closed: \(mapped.localizedDescription, privacy: .public)")
                drop(connectionID, error: mapped)
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let data = try? Self.data(of: message),
              let envelope = try? Self.decode(OBSEnvelope.self, from: data) else { return }
        switch envelope.op {
        case 7:
            if let id = envelope.d?.requestId {
                // Tagged now, not when the caller resumes: a StreamStateChanged queued right behind
                // this response must not make an old reading look like part of the new stream.
                settle(id, with: .success((data, epoch)))
            }
        case 5:
            if envelope.d?.eventType == "StreamStateChanged" {
                epoch += 1
                Log.obs.info("OBS stream state changed")
            }
        default:
            break
        }
    }

    private func timeOut(_ id: String, connectionID: Int, requestType: String) {
        guard pending[id] != nil else { return }
        let error = EncoderError.timedOut("OBS did not answer \(requestType)")
        drop(connectionID, error: error)
        // `drop` only fails the current connection's requests; this one is settled regardless.
        settle(id, with: .failure(error))
    }

    private func settle(_ id: String, with result: Result<(Data, Int), any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Closes the given connection if it is still the current one and fails its pending requests.
    private func drop(_ connectionID: Int, error: any Error) {
        guard let current = connection, current.id == connectionID else { return }
        connection = nil
        current.receiver?.cancel()
        current.task.cancel(with: .goingAway, reason: nil)
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    nonisolated static func withDeadline<T: Sendable>(_ timeout: Duration, _ description: String,
                                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw EncoderError.timedOut(description)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Our own errors pass through; a 4009 close is a rejected password; transport errors mean
    /// OBS is not reachable.
    nonisolated static func map(_ error: any Error, closeCode: URLSessionWebSocketTask.CloseCode) -> any Error {
        if error is EncoderError || error is CancellationError { return error }
        if closeCode.rawValue == authenticationFailedCloseCode { return EncoderError.authenticationFailed }
        if closeCode.rawValue >= 4000 {
            return EncoderError.protocolError("obs-websocket closed the connection (code \(closeCode.rawValue))")
        }
        if error is DecodingError { return EncoderError.protocolError(String(describing: error)) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return EncoderError.unavailable(error.localizedDescription)
        }
        return error
    }

    private nonisolated static func receive<Body: Decodable & Sendable>(
        _ type: OBSMessage<Body>.Type, from task: URLSessionWebSocketTask, expectingOp op: Int
    ) async throws -> OBSMessage<Body> {
        let data = try data(of: try await task.receive())
        let envelope = try decode(OBSEnvelope.self, from: data)
        guard envelope.op == op else {
            throw EncoderError.protocolError("expected opcode \(op), got \(envelope.op)")
        }
        return try decode(type, from: data)
    }

    private nonisolated static func data(of message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .string(let text):
            Data(text.utf8)
        case .data(let data):
            data
        @unknown default:
            throw EncoderError.protocolError("unknown WebSocket message type")
        }
    }

    private nonisolated static func encode<Body: Encodable & Sendable>(_ message: OBSMessage<Body>) throws -> URLSessionWebSocketTask.Message {
        .string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self))
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EncoderError.protocolError(error.localizedDescription)
        }
    }
}
