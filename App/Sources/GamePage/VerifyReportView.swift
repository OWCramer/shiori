// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SteamKit
import SwiftUI

/// What the last Verify Files found: everything matching Steam, or the files that differ.
struct VerifyReportView: View {
    let report: VerifyReport
    let patchCount: Int

    private static let shown = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.isClean {
                Label("All \(report.checkedFiles) files match Steam", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.teal)
            } else {
                Label("\(report.problems.count) of \(report.checkedFiles) files differ from Steam", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                ForEach(report.problems.keys.sorted().prefix(Self.shown), id: \.self) { path in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path).font(.footnote.monospaced())
                        Text(describe(report.problems[path]!)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !report.extraFiles.isEmpty {
                Text("\(report.extraFiles.count) extra files in base")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if patchCount > 0 {
                Text("Plus \(patchCount) patch file\(patchCount == 1 ? "" : "s") in patch/")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private func describe(_ problem: VerifyReport.Problem) -> String {
        switch problem {
        case .missing: "Missing"
        case let .wrongSize(expected, actual): "Size \(actual.formatted(.byteCount(style: .file))), expected \(expected.formatted(.byteCount(style: .file)))"
        case .modified: "Contents changed"
        }
    }
}
