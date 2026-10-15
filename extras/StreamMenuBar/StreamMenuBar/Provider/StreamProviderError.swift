//
//  StreamProviderError.swift
//  StreamMenuBar
//

import Foundation

/// Errors shared by the provider layer. The first three cases change `AppModel.authStatus`;
/// everything else is shown as a transient error and the poll retries with backoff.
nonisolated enum StreamProviderError: Error, LocalizedError, Equatable {
    /// No client ID and secret stored yet.
    case missingCredentials
    /// No user tokens stored.
    case notSignedIn
    /// The stored tokens are no longer accepted; the user has to sign in again.
    case reauthorizationRequired(reason: String)
    /// The user cancelled, or the provider refused the authorization request.
    case authorizationDenied(String)
    /// The redirect carried a `state` from a different sign-in attempt.
    case stateMismatch
    case signInTimedOut
    case redirectPortUnavailable(UInt16)
    /// An OAuth error response from the token endpoint.
    case oauth(code: String, description: String?)
    case httpStatus(Int, body: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Add your Kick app's client ID and secret in Settings."
        case .notSignedIn:
            "Not signed in."
        case .reauthorizationRequired(let reason):
            "Sign in again (\(reason))."
        case .authorizationDenied(let detail):
            "Sign-in was not completed: \(detail)"
        case .stateMismatch:
            "The sign-in response did not match this sign-in attempt."
        case .signInTimedOut:
            "Timed out waiting for the sign-in to finish in the browser."
        case .redirectPortUnavailable(let port):
            "Could not listen on localhost port \(port) for the sign-in redirect."
        case .oauth(let code, let description):
            description.map { "\($0) (\(code))" } ?? code
        case .httpStatus(let status, let body):
            body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
        case .invalidResponse(let detail):
            "Unexpected response: \(detail)"
        }
    }
}
