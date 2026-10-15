//
//  Log.swift
//  StreamMenuBar
//

import os

/// Unified-logging categories. Read them with
/// `log stream --predicate 'subsystem == "dev.sebastiansuarez.StreamMenuBar"'` or in the Xcode console.
/// Nothing here logs a token, a code, a password, or a secret.
nonisolated enum Log {
    static let subsystem = "dev.sebastiansuarez.StreamMenuBar"
    static let signIn = Logger(subsystem: subsystem, category: "sign-in")
    static let redirect = Logger(subsystem: subsystem, category: "redirect")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let poll = Logger(subsystem: subsystem, category: "poll")
    static let obs = Logger(subsystem: subsystem, category: "obs")
}
