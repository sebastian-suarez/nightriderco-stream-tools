//
//  OBSMessages.swift
//  StreamMenuBar
//

import CryptoKit
import Foundation

// obs-websocket 5 wire format (github.com/obsproject/obs-websocket, docs/generated/protocol.md).
// Every message is `{"op": <opcode>, "d": {...}}`. Only the fields this app uses are modelled.

nonisolated struct OBSMessage<Body: Sendable>: Sendable {
    var op: Int
    var d: Body
}

extension OBSMessage: Encodable where Body: Encodable {}
extension OBSMessage: Decodable where Body: Decodable {}

/// Enough of any incoming message to route it: the opcode, and the request ID or event type.
nonisolated struct OBSEnvelope: Decodable, Sendable {
    var op: Int
    var d: Routing?

    nonisolated struct Routing: Decodable, Sendable {
        var requestId: String?
        var eventType: String?
    }
}

/// Hello (op 0), sent by the server right after the connection opens.
nonisolated struct OBSHello: Decodable, Sendable {
    var obsWebSocketVersion: String?
    var obsStudioVersion: String?
    var rpcVersion: Int
    /// Present when the server requires a password.
    var authentication: Challenge?

    nonisolated struct Challenge: Decodable, Sendable {
        var challenge: String
        var salt: String
    }
}

/// Identify (op 1), the client's reply to Hello.
nonisolated struct OBSIdentify: Encodable, Sendable {
    var rpcVersion: Int
    var authentication: String?
    /// Bit mask of event categories to receive.
    var eventSubscriptions: Int
}

/// Identified (op 2).
nonisolated struct OBSIdentified: Decodable, Sendable {
    var negotiatedRpcVersion: Int
}

/// Request (op 6).
nonisolated struct OBSRequest: Encodable, Sendable {
    var requestType: String
    var requestId: String
}

/// RequestResponse (op 7).
nonisolated struct OBSRequestResponse<Response: Decodable & Sendable>: Decodable, Sendable {
    var requestType: String
    var requestId: String
    var requestStatus: Status
    var responseData: Response?

    nonisolated struct Status: Decodable, Sendable {
        var result: Bool
        /// 100 is success; see RequestStatus in the protocol document.
        var code: Int
        var comment: String?
    }
}

/// `GetStreamStatus` response data.
nonisolated struct OBSStreamStatus: Decodable, Sendable, Equatable {
    var outputActive: Bool
    var outputReconnecting: Bool?
    var outputBytes: Int64
    /// Milliseconds, derived by OBS from the frame count, so it stalls when encoding stalls.
    var outputDuration: Int64?
    var outputTimecode: String?
    var outputCongestion: Double?
    var outputSkippedFrames: Int?
    var outputTotalFrames: Int?
}

/// A response plus the client's epoch at the time it arrived (see `OBSWebSocketClient.epoch`).
nonisolated struct OBSReply<Response: Sendable>: Sendable {
    var data: Response
    var epoch: Int
}

nonisolated enum OBSAuthentication {
    /// `base64(sha256(base64(sha256(password + salt)) + challenge))`, as the protocol specifies.
    static func response(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }
}
