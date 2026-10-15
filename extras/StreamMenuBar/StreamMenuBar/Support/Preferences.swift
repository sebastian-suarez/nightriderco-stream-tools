//
//  Preferences.swift
//  StreamMenuBar
//

import Foundation

/// Keys and defaults for the plain preferences kept in `UserDefaults` (`@AppStorage` in views).
nonisolated enum Preferences {
    static let refreshIntervalKey = "refreshIntervalSeconds"
    static let defaultRefreshInterval: TimeInterval = 30
    static let refreshIntervalChoices: [TimeInterval] = [10, 15, 30, 60, 120, 300]
    static let minimumRefreshInterval: TimeInterval = 5
    /// Longest wait between polls while requests keep failing.
    static let maximumBackoffInterval: TimeInterval = 300

    // OBS (obs-websocket on this Mac). The password lives in the Keychain, not here.
    static let obsEnabledKey = "obsEnabled"
    static let obsPortKey = "obsPort"
    static let defaultOBSPort = 4455
    static let obsPasswordAccount = "obs.password"
    /// OBS is local, so it is polled more often than Kick.
    static let obsPollInterval: Duration = .seconds(5)
    /// Wait between attempts while OBS is unreachable or rejects the password.
    static let obsRetryInterval: Duration = .seconds(15)

    static func refreshInterval(from defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.double(forKey: refreshIntervalKey)
        return stored >= minimumRefreshInterval ? stored : defaultRefreshInterval
    }

    static func label(forRefreshInterval seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }

    /// On until the user turns it off.
    static func obsEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: obsEnabledKey) == nil ? true : defaults.bool(forKey: obsEnabledKey)
    }

    static func obsPort(from defaults: UserDefaults = .standard) -> UInt16 {
        let stored = defaults.integer(forKey: obsPortKey)
        return (1...Int(UInt16.max)).contains(stored) ? UInt16(stored) : UInt16(defaultOBSPort)
    }
}
