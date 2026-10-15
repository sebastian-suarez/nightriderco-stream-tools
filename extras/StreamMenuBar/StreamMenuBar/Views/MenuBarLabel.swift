//
//  MenuBarLabel.swift
//  StreamMenuBar
//

import SwiftUI

/// What sits in the status bar: the app glyph, the viewer count while live, and the bitrate
/// while OBS is streaming, side by side.
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "dot.radiowaves.left.and.right")
            if let text {
                Text(text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.map { "Stream menu bar, \($0)" } ?? "Stream menu bar")
    }

    private var text: String? {
        let parts = [kickText, bitrateText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var kickText: String? {
        switch model.authStatus {
        case .signedIn:
            guard let snapshot = model.snapshot else { return "…" }
            switch snapshot.isLive {
            case true:
                return snapshot.viewerCount.map { $0.formatted() } ?? "–"
            case false:
                return "Offline"
            default:
                return "–"
            }
        case .signingIn:
            return "Signing in…"
        case .reauthorizationRequired:
            return "Sign in"
        case .loading, .needsCredentials, .signedOut:
            return nil
        }
    }

    private var bitrateText: String? {
        guard let status = model.encoderStatus, status.isStreaming else { return nil }
        return status.bitrateKbps.map { EncoderStatus.bitrateText(kbps: $0) } ?? "… kb/s"
    }
}
