import Foundation
import HealthKit

struct ImportReport {
    var written = 0
    var skipped = 0
    var overwritten = 0
    var duplicatesCollapsed = 0
    var existingFound = 0
    var failed: [ParseIssue] = []
    var log: [String] = []
}

actor ImportEngine {
    private let health = HealthKitManager()

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd h:mm a"
        return f
    }()

    private func stamp(_ d: Date) -> String { Self.logFormatter.string(from: d) }

    /// Counts existing body-mass samples over the span the rows cover, without importing.
    /// Used by the UI to prove read access was actually granted.
    func preflight(rows: [WeightRow]) async throws -> Int {
        try await health.requestAuthorization()
        guard let (start, end) = span(of: rows) else { return 0 }
        let existing = try await health.existingMinutes(from: start, to: end)
        return existing.anySource.count
    }

    func run(rows allRows: [WeightRow], issues: [ParseIssue], overwrite: Bool) async throws -> ImportReport {
        var report = ImportReport()
        report.failed = issues

        // 1. Authorization. Only auth / availability problems throw.
        try await health.requestAuthorization()

        guard !allRows.isEmpty else {
            report.log.append("No valid rows to import.")
            return report
        }

        // 2. Collapse exact duplicates inside the CSV (same minute AND same value).
        var seen = Set<String>()
        var rows: [WeightRow] = []
        for r in allRows {
            let key = "\(HealthKitManager.minuteKey(r.date))|\(String(format: "%.4f", r.pounds))"
            if seen.insert(key).inserted {
                rows.append(r)
            } else {
                report.duplicatesCollapsed += 1
                report.log.append("Line \(r.line): duplicate of an earlier row (\(stamp(r.date)), \(String(format: "%.1f", r.pounds)) lb) — collapsed.")
            }
        }

        // 3. One query over the whole span, padded by a day on each side.
        guard let (start, end) = span(of: rows) else { return report }
        let existing = try await health.existingMinutes(from: start, to: end)
        report.existingFound = existing.anySource.count
        report.log.append("Existing entries found in Health over this span: \(existing.anySource.count) minute(s).")

        // 4. Decide per row.
        var toWrite: [WeightRow] = []
        var samplesToDelete: [HKQuantitySample] = []
        var deletedMinutes = Set<HealthKitManager.MinuteKey>()

        for row in rows {
            let k = HealthKitManager.minuteKey(row.date)

            guard existing.anySource.contains(k) else {
                toWrite.append(row)
                continue
            }

            if !overwrite {
                report.skipped += 1
                report.log.append("\(stamp(row.date)) skipped: existing entry.")
                continue
            }

            // Overwrite is on.
            let mine = existing.own[k] ?? []
            if mine.isEmpty {
                report.log.append("\(stamp(row.date)): entry belongs to another source and cannot be replaced — CSV value added alongside it.")
            } else if deletedMinutes.insert(k).inserted {
                samplesToDelete.append(contentsOf: mine)
                report.overwritten += 1
                report.log.append("\(stamp(row.date)): replacing \(mine.count) entry(ies) written by this app.")
            }
            toWrite.append(row)
        }

        // 5. Delete first, then write.
        if !samplesToDelete.isEmpty {
            do {
                try await health.delete(samplesToDelete)
            } catch {
                report.log.append("Delete failed (\(error.localizedDescription)); the CSV values were added alongside the old ones instead.")
                report.overwritten = 0
            }
        }

        let samples = health.makeSamples(toWrite)
        do {
            try await health.save(samples)
            report.written = samples.count
        } catch {
            // Fall back to chunks so one bad sample doesn't sink the whole batch.
            report.log.append("Bulk save failed (\(error.localizedDescription)); retrying in chunks of 200.")
            var written = 0
            for chunkStart in stride(from: 0, to: toWrite.count, by: 200) {
                let slice = Array(toWrite[chunkStart..<min(chunkStart + 200, toWrite.count)])
                do {
                    try await health.save(health.makeSamples(slice))
                    written += slice.count
                } catch {
                    for row in slice {
                        report.failed.append(ParseIssue(line: row.line,
                                                        reason: "Save failed: \(error.localizedDescription)"))
                    }
                }
            }
            report.written = written
        }

        report.log.append("Done: \(report.written) written, \(report.skipped) skipped, \(report.overwritten) overwritten.")
        return report
    }

    private func span(of rows: [WeightRow]) -> (Date, Date)? {
        guard let min = rows.map(\.date).min(), let max = rows.map(\.date).max() else { return nil }
        return (min.addingTimeInterval(-86_400), max.addingTimeInterval(86_400))
    }
}
