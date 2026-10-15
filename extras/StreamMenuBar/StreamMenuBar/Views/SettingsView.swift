//
//  SettingsView.swift
//  StreamMenuBar
//

import AppKit
import SwiftUI

struct SettingsView: View {
    var model: AppModel

    @AppStorage(Preferences.refreshIntervalKey) private var refreshInterval = Preferences.defaultRefreshInterval
    @AppStorage(Preferences.obsEnabledKey) private var obsEnabled = true
    @AppStorage(Preferences.obsPortKey) private var obsPort = Preferences.defaultOBSPort
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var hasLoadedCredentials = false
    @State private var credentialsMessage: String?
    @State private var obsPassword = ""
    @State private var obsPasswordMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientID)
                    .accessibilityIdentifier("clientID")
                SecureField("Client secret", text: $clientSecret)
                    .accessibilityIdentifier("clientSecret")
                HStack {
                    Button("Save") {
                        saveCredentials()
                    }
                    .accessibilityIdentifier("saveCredentials")
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty
                              || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let credentialsMessage {
                        Text(credentialsMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Kick app")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create an app at kick.com/settings/developer and register this redirect URL on it, then paste its client ID and secret here. They are stored in your Keychain.")
                    Text(KickOAuth.redirectURI)
                        .monospaced()
                        .textSelection(.enabled)
                    Link("Open Kick developer settings", destination: URL(string: "https://kick.com/settings/developer")!)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Account") {
                LabeledContent("Status", value: statusText)
                accountButton
                if let error = model.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Refresh") {
                Picker("Every", selection: $refreshInterval) {
                    ForEach(Preferences.refreshIntervalChoices, id: \.self) { seconds in
                        Text(Preferences.label(forRefreshInterval: seconds)).tag(seconds)
                    }
                }
                .accessibilityIdentifier("refreshInterval")
            }

            Section {
                Toggle("Show the stream bitrate from OBS", isOn: $obsEnabled)
                    .accessibilityIdentifier("obsEnabled")
                TextField("Port", value: $obsPort, format: .number.grouping(.never))
                    .accessibilityIdentifier("obsPort")
                    .disabled(!obsEnabled)
                SecureField("Server password", text: $obsPassword)
                    .accessibilityIdentifier("obsPassword")
                    .disabled(!obsEnabled)
                HStack {
                    Button("Save password") {
                        saveEncoderPassword()
                    }
                    .accessibilityIdentifier("saveObsPassword")
                    .disabled(!obsEnabled)
                    if let obsPasswordMessage {
                        Text(obsPasswordMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Status", value: encoderStatusText)
            } header: {
                Text("OBS Studio")
            } footer: {
                Text("In OBS, open Tools › WebSocket Server Settings, enable the server, and copy its port and password here. The password is stored in your Keychain. Only OBS on this Mac is supported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task {
            guard !hasLoadedCredentials else { return }
            hasLoadedCredentials = true
            if let stored = await model.storedCredentials() {
                clientID = stored.clientID
                clientSecret = stored.clientSecret
            }
            obsPassword = model.storedEncoderPassword() ?? ""
        }
        .onAppear {
            // A menu bar app has no Dock icon to click, so bring the window forward ourselves.
            NSApplication.shared.activate()
        }
        .onChange(of: refreshInterval) {
            model.refreshIntervalChanged()
        }
        .onChange(of: obsEnabled) {
            model.encoderSettingsChanged()
        }
        .onChange(of: obsPort) {
            // The text field accepts any integer; keep the stored port in range.
            let clamped = min(max(obsPort, 1), Int(UInt16.max))
            if clamped != obsPort {
                obsPort = clamped
                return
            }
            model.encoderSettingsChanged()
        }
    }

    private var encoderStatusText: String {
        switch model.encoderState {
        case .disabled:
            "Off"
        case .connecting:
            "Connecting…"
        case .connected(let status):
            status.isStreaming
                ? "Streaming\(status.bitrateKbps.map { " at \(EncoderStatus.bitrateText(kbps: $0))" } ?? "")"
                : "Connected, not streaming"
        case .failed(.unavailable):
            "Not connected. Is the WebSocket server enabled in OBS on port \(obsPort)?"
        case .failed(let error):
            error.localizedDescription
        }
    }

    private var statusText: String {
        switch model.authStatus {
        case .loading:
            "Loading…"
        case .needsCredentials:
            "Waiting for Kick app credentials"
        case .signedOut:
            "Not signed in"
        case .signingIn:
            "Waiting for the browser…"
        case .signedIn:
            model.snapshot?.channelName.map { "Signed in as \($0)" } ?? "Signed in"
        case .reauthorizationRequired:
            "Sign in again"
        }
    }

    @ViewBuilder
    private var accountButton: some View {
        switch model.authStatus {
        case .signedIn:
            Button("Sign out") {
                model.signOut()
            }
        case .signingIn:
            Button("Cancel sign-in") {
                model.cancelSignIn()
            }
        case .loading, .needsCredentials, .signedOut, .reauthorizationRequired:
            Button("Sign in with Kick…") {
                model.signIn()
            }
            .disabled(model.authStatus == .needsCredentials || model.authStatus == .loading)
        }
    }

    private func saveEncoderPassword() {
        do {
            try model.saveEncoderPassword(obsPassword)
            obsPasswordMessage = "Saved."
        } catch {
            obsPasswordMessage = error.localizedDescription
        }
    }

    private func saveCredentials() {
        Task {
            do {
                try await model.saveCredentials(clientID: clientID, clientSecret: clientSecret)
                credentialsMessage = "Saved."
            } catch {
                credentialsMessage = error.localizedDescription
            }
        }
    }
}
