//
//  EncoderStatus.swift
//  StreamMenuBar
//

import Foundation

/// One reading of the local encoder (OBS Studio), taken at `fetchedAt`.
nonisolated struct EncoderStatus: Sendable, Equatable {
    var isStreaming: Bool
    /// Output bitrate in kilobits per second. nil while not streaming, and until two samples
    /// exist after a (re)connection or a stream restart.
    var bitrateKbps: Int?
    var fetchedAt: Date

    /// "8041 kb/s": the unit OBS's own status bar uses.
    static func bitrateText(kbps: Int) -> String {
        "\(kbps.formatted(.number.grouping(.never))) kb/s"
    }
}

/// A platform-neutral source of encoder metrics. OBS is the only implementation for now;
/// UI code depends on this protocol and `EncoderStatus` only.
nonisolated protocol EncoderProvider: Sendable {
    /// Fetches the current values. Throws an `EncoderError`; every case is transient and the
    /// caller retries later.
    func fetchStatus() async throws -> EncoderStatus
    /// Closes any open connection. Called when the provider is replaced or disabled.
    func disconnect() async
}

nonisolated enum EncoderError: Error, LocalizedError, Equatable {
    /// The encoder is not running, its server is off, or it listens on another port.
    case unavailable(String)
    /// The encoder requires a password and none is stored, or the stored one was rejected.
    case authenticationFailed
    case timedOut(String)
    case protocolError(String)
    case requestFailed(code: Int, comment: String?)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "OBS is not reachable: \(detail)"
        case .authenticationFailed:
            "OBS needs its WebSocket server password. Check it in Settings."
        case .timedOut(let detail):
            "Timed out: \(detail)"
        case .protocolError(let detail):
            "Unexpected OBS response: \(detail)"
        case .requestFailed(let code, let comment):
            "OBS refused the request (\(code)\(comment.map { ": \($0)" } ?? ""))"
        }
    }
}
