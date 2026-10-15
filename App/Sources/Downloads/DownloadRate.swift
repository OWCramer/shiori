// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// How fast a download is going, from its progress reports over the last several seconds,
/// and how long the rest should take at that pace.
struct DownloadRate: Equatable {
    private struct Sample: Equatable {
        var date: Date
        var bytes: UInt64
    }

    private var samples: [Sample] = []
    /// How far back the pace is measured.
    private static let window: TimeInterval = 8

    /// Notes the bytes done so far.
    mutating func record(_ bytes: UInt64, at date: Date = .now) {
        // A restart (fewer bytes than before) starts the measurement over.
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append(Sample(date: date, bytes: bytes))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
    }

    /// Bytes a second, once there's a couple of seconds to go on.
    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.date.timeIntervalSince(first.date)
        guard seconds >= 2, last.bytes > first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / seconds
    }

    /// Time left for `remaining` bytes at the current pace.
    func timeLeft(remaining: UInt64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(remaining) / rate
    }
}
