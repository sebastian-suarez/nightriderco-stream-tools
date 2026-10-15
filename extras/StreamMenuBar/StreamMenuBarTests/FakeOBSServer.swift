//
//  FakeOBSServer.swift
//  StreamMenuBarTests
//

import CryptoKit
import Foundation
import Network
import Synchronization

/// An in-process obs-websocket 5 server on the loopback interface, with its own (independent)
/// implementation of the password check. Behaviour is fixed per instance.
final class FakeOBSServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (_ requestType: String) -> (status: [String: Any], responseData: [String: Any]?)

    struct Behaviour {
        var password: String?
        /// Accept connections but never send Hello.
        var silent = false
        /// Identify, but never answer requests.
        var answersRequests = true
        /// Send Identified and close the socket at once, like OBS quitting right after the handshake.
        var closesAfterIdentify = false
        /// Event types to send right behind every response, in the same write.
        var eventsAfterResponse: [String] = []
        var handler: RequestHandler = { _ in (["result": true, "code": 100], ["outputActive": false, "outputBytes": 0]) }
    }

    private struct State {
        var ready: CheckedContinuation<Void, any Error>?
        var connections: [NWConnection] = []
        var identified = 0
    }

    let port: UInt16
    private let behaviour: Behaviour
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-obs")
    private let state = Mutex(State())

    private init(listener: NWListener, port: UInt16, behaviour: Behaviour) {
        self.listener = listener
        self.port = port
        self.behaviour = behaviour
    }

    static func start(port: UInt16, _ behaviour: Behaviour = Behaviour()) async throws -> FakeOBSServer {
        var attempt = 0
        while true {
            do {
                return try await bind(port: port, behaviour: behaviour)
            } catch where attempt < 5 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private static func bind(port: UInt16, behaviour: Behaviour) async throws -> FakeOBSServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setSubprotocols(["obswebsocket.json"])
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        let server = FakeOBSServer(listener: listener, port: port, behaviour: behaviour)
        try await server.waitUntilReady()
        return server
    }

    var identifiedCount: Int { state.withLock { $0.identified } }

    /// Closes every open connection the way a crashed or quit OBS would.
    func dropConnections() {
        let connections = state.withLock { locked -> [NWConnection] in
            defer { locked.connections = [] }
            return locked.connections
        }
        connections.forEach { $0.cancel() }
    }

    func sendEvent(type: String, data: [String: Any] = [:]) {
        let connections = state.withLock { $0.connections }
        for connection in connections {
            send(["op": 5, "d": ["eventType": type, "eventIntent": 64, "eventData": data]], on: connection)
        }
    }

    func stop() {
        dropConnections()
        listener.cancel()
    }

    static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    // MARK: - Private

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { $0.ready = continuation }
            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.resumeReady(.success(()))
                case .waiting(let error), .failed(let error):
                    self.resumeReady(.failure(error))
                case .cancelled:
                    self.resumeReady(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
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

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        let challenge = behaviour.password == nil ? nil : (challenge: Self.random(), salt: Self.random())
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self, case .ready = newState, !self.behaviour.silent else { return }
            var hello: [String: Any] = ["obsWebSocketVersion": "5.7.4", "obsStudioVersion": "32.2.2", "rpcVersion": 1]
            if let challenge {
                hello["authentication"] = ["challenge": challenge.challenge, "salt": challenge.salt]
            }
            self.send(["op": 0, "d": hello], on: connection)
        }
        connection.start(queue: queue)
        receive(on: connection, challenge: challenge)
    }

    private func receive(on connection: NWConnection, challenge: (challenge: String, salt: String)?) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                connection.cancel()
                return
            }
            if let content {
                self.handle(content, on: connection, challenge: challenge)
            }
            self.receive(on: connection, challenge: challenge)
        }
    }

    private func handle(_ content: Data, on connection: NWConnection, challenge: (challenge: String, salt: String)?) {
        guard let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
              let op = json["op"] as? Int, let d = json["d"] as? [String: Any] else { return }
        switch op {
        case 1:
            if let password = behaviour.password, let challenge {
                let expected = Self.authentication(password: password, salt: challenge.salt, challenge: challenge.challenge)
                guard d["authentication"] as? String == expected else {
                    close(connection, code: 4009, reason: "Authentication failed.")
                    return
                }
            }
            state.withLock { $0.identified += 1 }
            send(["op": 2, "d": ["negotiatedRpcVersion": 1]], on: connection)
            if behaviour.closesAfterIdentify {
                close(connection, code: 1001, reason: "Going away.")
            }
        case 6:
            guard behaviour.answersRequests else { return }
            let requestType = d["requestType"] as? String ?? ""
            let (status, responseData) = behaviour.handler(requestType)
            var reply: [String: Any] = ["requestType": requestType, "requestId": d["requestId"] ?? "", "requestStatus": status]
            if let responseData {
                reply["responseData"] = responseData
            }
            send(["op": 7, "d": reply], on: connection)
            for eventType in behaviour.eventsAfterResponse {
                send(["op": 5, "d": ["eventType": eventType, "eventIntent": 64, "eventData": [:]]], on: connection)
            }
        default:
            break
        }
    }

    private func send(_ json: [String: Any], on connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func close(_ connection: NWConnection, code: UInt16, reason: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code >= 4000 ? .privateCode(code) : .protocolCode(.init(rawValue: code) ?? .goingAway)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: Data(reason.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func random() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }
}
