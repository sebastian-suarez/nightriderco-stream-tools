//
//  AppModel.swift
//  StreamMenuBar
//

import AppKit
import Foundation
import Observation
import os

/// The one main-actor model the views read. Owns the sign-in flow, the Kick poll loop, and the
/// OBS poll loop. The two loops are independent: OBS needs no Kick sign-in, and a failure in one
/// never touches the other's values.
@MainActor @Observable
final class AppModel {
    enum AuthStatus: Equatable {
        case loading
        case needsCredentials
        case signedOut
        case signingIn
        case signedIn
        case reauthorizationRequired(String)
    }

    /// The OBS side. A failed poll replaces the last reading, so a stale bitrate is never shown.
    enum EncoderState: Equatable {
        case disabled
        case connecting
        case connected(EncoderStatus)
        case failed(EncoderError)
    }

    private(set) var authStatus: AuthStatus = .loading
    private(set) var snapshot: StreamSnapshot?
    /// The most recent failure, kept until a refresh or sign-in succeeds.
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var encoderState: EncoderState = .disabled

    @ObservationIgnored private let auth: KickAuthSession
    @ObservationIgnored private let provider: any StreamProvider
    @ObservationIgnored private let makeEncoderProvider: (OBSWebSocketClient.Configuration) -> any EncoderProvider
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var encoderTask: Task<Void, Never>?
    /// Incremented whenever the OBS loop is (re)started; a poll from an older generation must
    /// not publish its result.
    @ObservationIgnored private var encoderGeneration = 0

    init(auth: KickAuthSession = KickAuthSession(), provider: (any StreamProvider)? = nil,
         keychain: KeychainStore = .app,
         makeEncoderProvider: ((OBSWebSocketClient.Configuration) -> any EncoderProvider)? = nil) {
        self.auth = auth
        self.provider = provider ?? KickStreamProvider(api: KickAPIClient(auth: auth))
        self.keychain = keychain
        self.makeEncoderProvider = makeEncoderProvider ?? { OBSEncoderProvider(configuration: $0) }
    }

    var isSignedIn: Bool { authStatus == .signedIn }

    /// The bitrate to show, while OBS reports that it is streaming.
    var encoderStatus: EncoderStatus? {
        if case .connected(let status) = encoderState { return status }
        return nil
    }

    /// Reads the Keychain and starts polling when a session exists. Call once at launch.
    func start() {
        Task { await reloadAuthStatus() }
        startEncoderPolling()
    }

    // MARK: Credentials

    func storedCredentials() async -> KickAppCredentials? {
        try? await auth.credentials()
    }

    func saveCredentials(clientID: String, clientSecret: String) async throws {
        try await auth.storeCredentials(KickAppCredentials(clientID: clientID, clientSecret: clientSecret))
        if authStatus != .signingIn {
            await reloadAuthStatus()
        }
    }

    // MARK: Sign-in

    /// Opens the browser at Kick's authorize page and completes the flow when the redirect arrives.
    func signIn() {
        guard signInTask == nil else { return }
        signInTask = Task {
            await performSignIn()
            signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func signOut() {
        signInTask?.cancel()
        stopPolling()
        snapshot = nil
        lastError = nil
        Task {
            await auth.signOut()
            await reloadAuthStatus()
        }
    }

    // MARK: Polling

    func refreshNow() {
        guard isSignedIn else { return }
        startPolling()
    }

    /// Call when the refresh interval preference changes so the new interval applies at once.
    func refreshIntervalChanged() {
        guard isSignedIn, pollTask != nil else { return }
        startPolling()
    }

    // MARK: OBS

    /// Call when the OBS toggle or port changes: the loop restarts with the new settings.
    func encoderSettingsChanged() {
        startEncoderPolling()
    }

    func storedEncoderPassword() -> String? {
        guard let data = try? keychain.data(for: Preferences.obsPasswordAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the obs-websocket password in the Keychain (an empty one removes it) and reconnects.
    func saveEncoderPassword(_ password: String) throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.remove(Preferences.obsPasswordAccount)
        } else {
            try keychain.set(Data(trimmed.utf8), for: Preferences.obsPasswordAccount)
        }
        startEncoderPolling()
    }

    // MARK: - Private

    private func reloadAuthStatus() async {
        do {
            guard try await auth.credentials() != nil else {
                authStatus = .needsCredentials
                Log.auth.info("No credentials stored; waiting for Settings")
                return
            }
            if try await auth.isSignedIn() {
                authStatus = .signedIn
                Log.auth.info("Tokens found; polling")
                startPolling()
            } else {
                authStatus = .signedOut
                Log.auth.info("Credentials found, no tokens; signed out")
            }
        } catch {
            authStatus = .signedOut
            lastError = error.localizedDescription
            Log.auth.error("Keychain read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performSignIn() async {
        do {
            guard let credentials = try await auth.credentials() else {
                authStatus = .needsCredentials
                return
            }
            stopPolling()
            authStatus = .signingIn
            lastError = nil

            let pkce = PKCE()
            let state = PKCE.randomURLSafeString(byteCount: 16)
            Log.signIn.info("Starting sign-in; binding localhost:\(KickOAuth.redirectPort)")
            // Listen before opening the browser so the redirect always has somewhere to land.
            let server = try await LoopbackRedirectServer.start(port: KickOAuth.redirectPort, expectedState: state)
            defer { server.stop() }
            let url = KickOAuth.authorizationURL(clientID: credentials.clientID, codeChallenge: pkce.challenge, state: state)
            guard NSWorkspace.shared.open(url) else {
                Log.signIn.error("NSWorkspace could not open the browser")
                throw StreamProviderError.invalidResponse("The browser could not be opened for the Kick sign-in page.")
            }
            Log.signIn.info("Browser opened at \(url.host() ?? "?", privacy: .public)\(url.path(), privacy: .public); waiting up to 5 min for the redirect")
            let code = try await server.waitForCode(timeout: .seconds(300))
            Log.signIn.info("Redirect received; exchanging the code")
            try await auth.completeSignIn(code: code, codeVerifier: pkce.verifier)
            Log.signIn.info("Sign-in complete")
            authStatus = .signedIn
            startPolling()
        } catch is CancellationError {
            Log.signIn.notice("Sign-in cancelled")
            await reloadAuthStatus()
        } catch {
            Log.signIn.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            await reloadAuthStatus()
        }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                guard isSignedIn else { return }
                do {
                    try await Task.sleep(for: .seconds(nextDelay()))
                } catch {
                    return
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The configured interval, doubled per consecutive failure up to five minutes.
    private func nextDelay() -> TimeInterval {
        let base = Preferences.refreshInterval()
        guard consecutiveFailures > 0 else { return base }
        let backoff = base * pow(2, Double(min(consecutiveFailures, 4)))
        return min(backoff, max(base, Preferences.maximumBackoffInterval))
    }

    private func startEncoderPolling() {
        encoderTask?.cancel()
        encoderTask = nil
        encoderGeneration += 1
        let generation = encoderGeneration
        guard Preferences.obsEnabled() else {
            encoderState = .disabled
            Log.obs.info("OBS polling off")
            return
        }
        let keychain = keychain
        let configuration = OBSWebSocketClient.Configuration(port: Preferences.obsPort()) {
            try keychain.data(for: Preferences.obsPasswordAccount).flatMap { String(data: $0, encoding: .utf8) }
        }
        let provider = makeEncoderProvider(configuration)
        encoderState = .connecting
        encoderTask = Task {
            defer { Task { await provider.disconnect() } }
            while !Task.isCancelled {
                let result: Result<EncoderStatus, any Error>
                do {
                    result = .success(try await provider.fetchStatus())
                } catch {
                    result = .failure(error)
                }
                // Settings may have changed while the fetch was suspended; only the current loop publishes.
                guard !Task.isCancelled, generation == encoderGeneration else { return }
                let delay: Duration
                switch result {
                case .success(let status):
                    encoderState = .connected(status)
                    delay = Preferences.obsPollInterval
                    Log.obs.debug("OBS: streaming=\(status.isStreaming) kbps=\(status.bitrateKbps ?? -1)")
                case .failure(let error):
                    encoderState = .failed(error as? EncoderError ?? .unavailable(error.localizedDescription))
                    delay = Preferences.obsRetryInterval
                    Log.obs.notice("OBS poll failed: \(error.localizedDescription, privacy: .public)")
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await provider.fetchSnapshot()
            lastError = nil
            consecutiveFailures = 0
            Log.poll.debug("Snapshot: live=\(self.snapshot?.isLive.map(String.init) ?? "nil", privacy: .public) viewers=\(self.snapshot?.viewerCount ?? -1)")
        } catch {
            // A cancelled poll (sign-out, restart) must not leave an error behind.
            guard !Task.isCancelled else { return }
            consecutiveFailures += 1
            lastError = error.localizedDescription
            Log.poll.error("Poll failed (\(self.consecutiveFailures) in a row): \(error.localizedDescription, privacy: .public)")
            switch error as? StreamProviderError {
            case .missingCredentials:
                authStatus = .needsCredentials
            case .notSignedIn:
                authStatus = .signedOut
            case .reauthorizationRequired(let reason):
                authStatus = .reauthorizationRequired(reason)
            default:
                break
            }
        }
    }
}
