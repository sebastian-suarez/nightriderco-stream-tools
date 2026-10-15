//
//  MenuContentView.swift
//  StreamMenuBar
//

import AppKit
import SwiftUI

/// The dropdown: the same values with detail, then actions.
struct MenuContentView: View {
    var model: AppModel

    var body: some View {
        statusRows
        encoderRow
        Divider()
        Button("Refresh now") {
            model.refreshNow()
        }
        .disabled(!model.isSignedIn)
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Stream menu bar") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var statusRows: some View {
        switch model.authStatus {
        case .loading:
            Text("Loading…")
        case .needsCredentials:
            Text("Add your Kick app credentials in Settings.")
        case .signedOut:
            Text("Not signed in")
            Button("Sign in with Kick…") {
                model.signIn()
            }
        case .signingIn:
            Text("Finish signing in to Kick in your browser.")
            Button("Cancel sign-in") {
                model.cancelSignIn()
            }
        case .reauthorizationRequired:
            Text("Kick needs you to sign in again.")
            Button("Sign in with Kick…") {
                model.signIn()
            }
        case .signedIn:
            if let snapshot = model.snapshot {
                Text(headline(for: snapshot))
                Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
            } else {
                Text("Loading…")
            }
        }
        if let error = model.lastError {
            Text(error)
        }
    }

    @ViewBuilder
    private var encoderRow: some View {
        switch model.encoderState {
        case .disabled:
            EmptyView()
        case .connecting:
            Text("OBS: connecting…")
        case .connected(let status):
            if status.isStreaming {
                Text("Bitrate: \(status.bitrateKbps.map { EncoderStatus.bitrateText(kbps: $0) } ?? "measuring…") (OBS)")
            } else {
                Text("OBS: not streaming")
            }
        case .failed(.unavailable):
            Text("OBS: not connected")
        case .failed(.authenticationFailed):
            Text("OBS: password needed. Set it in Settings.")
        case .failed(let error):
            Text("OBS: \(error.localizedDescription)")
        }
    }

    private func headline(for snapshot: StreamSnapshot) -> String {
        let name = snapshot.channelName.map { "\($0): " } ?? ""
        switch snapshot.isLive {
        case true:
            let viewers = snapshot.viewerCount.map { "\($0.formatted()) viewers" } ?? "viewer count unavailable"
            return "\(name)Live · \(viewers)"
        case false:
            return "\(name)Offline"
        default:
            return "\(name)Live state unavailable"
        }
    }
}
