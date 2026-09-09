import Foundation

// MARK: - Model

struct WeightRow: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let pounds: Double
    let line: Int

    static func == (a: WeightRow, b: WeightRow) -> Bool {
        a.date == b.date && a.pounds == b.pounds && a.line == b.line
    }
}

struct ParseIssue: Identifiable {
    let id = UUID()
    let line: Int
    let reason: String
}

struct ParseResult {
    var rows: [WeightRow] = []
    var issues: [ParseIssue] = []
    var detectedDateHeader: String?
    var detectedWeightHeader: String?
    /// True when the weight column header mentions kg — values are converted to pounds.
    var convertedFromKilograms = false
    /// The field separator that was auto-detected.
    var delimiter: Character = ","
}

// MARK: - Parser

enum CSVParser {

    // MARK: Tokenizer (RFC 4180)

    /// Splits CSV text into rows of fields. Handles quoted fields, "" escapes,
    /// delimiters and newlines inside quotes, and \r\n / \r / \n line endings.
    static func tokenize(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false

        // Strip a leading UTF-8 BOM (Excel exports one) at the scalar level —
        // grapheme clustering can hide it behind the first visible character.
        var scalars = Substring(text).unicodeScalars
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        let chars = Array(String(scalars))

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")   // escaped quote
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i += 1
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                    i += 1
                case delimiter:
                    row.append(field)
                    field = ""
                    i += 1
                // Swift treats "\r\n" as ONE Character, so isNewline covers
                // \n, \r and \r\n with a single test.
                case let c where c.isNewline:
                    row.append(field)
                    rows.append(row)
                    field = ""
                    row = []
                    i += 1
                default:
                    field.append(c)
                    i += 1
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop rows that are entirely empty (trailing newline, blank lines).
        return rows.filter { r in r.contains { !$0.trimmed.isEmpty } }
    }

    /// Picks the delimiter that yields the most consistent multi-column layout.
    /// Semicolon-separated exports are common, and their date fields often contain
    /// an unquoted comma ("2017-09-22, 11:19 AM") that would wreck comma splitting.
    static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: Character = ","
        var bestScore = -1.0

        for d in candidates {
            let rows = tokenize(text, delimiter: d).prefix(30)
            guard !rows.isEmpty else { continue }
            var counts: [Int: Int] = [:]
            for r in rows { counts[r.count, default: 0] += 1 }
            guard let (modal, hits) = counts.max(by: { $0.value < $1.value }), modal >= 2 else { continue }
            // Reward wider tables, but weight consistency far more heavily.
            let consistency = Double(hits) / Double(rows.count)
            let score = consistency * 100 + Double(min(modal, 10))
            if score > bestScore {
                bestScore = score
                best = d
            }
        }
        return best
    }

    // MARK: Date parsing

    private static let dateFormats = [
        "yyyy-MM-dd, h:mma",
        "yyyy-MM-dd, h:mm a",
        "yyyy-MM-dd h:mma",
        "yyyy-MM-dd h:mm a",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss",
        "M/d/yyyy, h:mma",
        "M/d/yyyy, h:mm a",
        "M/d/yyyy h:mma",
        "M/d/yyyy h:mm a",
        "M/d/yyyy HH:mm",
        "M/d/yyyy",
        "yyyy-MM-dd"
    ]

    private static let formatters: [DateFormatter] = dateFormats.map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = fmt
        f.isLenient = false
        return f
    }

    /// Formats whose pattern carries no time-of-day; these get noon so the sample
    /// stays on the intended calendar day in any time zone.
    private static let dateOnlyFormats: Set<String> = ["M/d/yyyy", "yyyy-MM-dd"]

    static func parseDate(_ raw: String) -> Date? {
        // Apple Numbers exports a narrow no-break space before AM/PM; normalize
        // that and other exotic spaces to a plain space.
        var s = raw.trimmed
        for junk in ["\u{202F}", "\u{00A0}", "\u{2009}", "\u{200A}"] {
            s = s.replacingOccurrences(of: junk, with: " ")
        }
        s = s.replacingOccurrences(of: "  ", with: " ")
        guard !s.isEmpty else { return nil }

        for (idx, f) in formatters.enumerated() {
            if let d = f.date(from: s) {
                if dateOnlyFormats.contains(dateFormats[idx]) {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = .current
                    return cal.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
                }
                return d
            }
        }
        // Last resort: ISO8601 with an explicit offset.
        return ISO8601DateFormatter().date(from: s)
    }

    static func parseWeight(_ raw: String) -> Double? {
        let cleaned = raw.trimmed
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "lbs", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "lb", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "kg", with: "", options: .caseInsensitive)
            .trimmed
        return Double(cleaned)
    }

    // MARK: Entry point

    static func parse(_ text: String) -> ParseResult {
        var result = ParseResult()
        let delimiter = detectDelimiter(text)
        result.delimiter = delimiter
        let grid = tokenize(text, delimiter: delimiter)
        guard !grid.isEmpty else {
            result.issues.append(ParseIssue(line: 0, reason: "File is empty."))
            return result
        }

        // A first row is a header when none of its cells parses as a number.
        let first = grid[0]
        let looksLikeHeader = !first.contains { parseWeight($0) != nil }
        let headers = looksLikeHeader ? first.map { $0.trimmed } : []
        let body = looksLikeHeader ? Array(grid.dropFirst()) : grid
        let firstBodyLine = looksLikeHeader ? 2 : 1

        guard !body.isEmpty else {
            result.issues.append(ParseIssue(line: 0, reason: "File has a header but no data rows."))
            return result
        }

        let columnCount = body.map(\.count).max() ?? 0
        func column(_ i: Int, of row: [String]) -> String { i < row.count ? row[i] : "" }

        // --- Weight column ---
        var weightIdx: Int? = headers.firstIndex { h in
            let l = h.lowercased()
            return l.contains("lb") || l.contains("weight") || l.contains("mass") || l.contains("kg")
        }
        if weightIdx == nil {
            weightIdx = (0..<columnCount).first { i in
                body.allSatisfy { parseWeight(column(i, of: $0)) != nil || column(i, of: $0).trimmed.isEmpty }
                    && body.contains { parseWeight(column(i, of: $0)) != nil }
            }
        }

        // --- Date column ---
        var dateIdx: Int? = headers.firstIndex { h in
            let l = h.lowercased()
            return l.contains("date") || l.contains("time")
        }
        if dateIdx == nil {
            dateIdx = (0..<columnCount).first { i in
                i != weightIdx && body.contains { parseDate(column(i, of: $0)) != nil }
            }
        }

        guard let wIdx = weightIdx else {
            result.issues.append(ParseIssue(line: 0, reason: "Could not find a weight column."))
            return result
        }
        guard let dIdx = dateIdx else {
            result.issues.append(ParseIssue(line: 0, reason: "Could not find a date column."))
            return result
        }

        if looksLikeHeader {
            result.detectedWeightHeader = wIdx < headers.count ? headers[wIdx] : nil
            result.detectedDateHeader = dIdx < headers.count ? headers[dIdx] : nil
        }

        // Only treat as kilograms when the header says kg and does not say lb.
        let headerText = (result.detectedWeightHeader ?? "").lowercased()
        let isKilograms = headerText.contains("kg") && !headerText.contains("lb")
        result.convertedFromKilograms = isKilograms

        for (offset, row) in body.enumerated() {
            let line = firstBodyLine + offset
            let rawDate = column(dIdx, of: row)
            let rawWeight = column(wIdx, of: row)

            if rawDate.trimmed.isEmpty && rawWeight.trimmed.isEmpty { continue }

            guard let date = parseDate(rawDate) else {
                result.issues.append(ParseIssue(line: line, reason: "Unrecognized date “\(rawDate.trimmed)”"))
                continue
            }
            guard var pounds = parseWeight(rawWeight) else {
                result.issues.append(ParseIssue(line: line, reason: "Unrecognized weight “\(rawWeight.trimmed)”"))
                continue
            }
            if isKilograms { pounds *= 2.20462262185 }
            guard pounds > 0, pounds <= 1500 else {
                result.issues.append(ParseIssue(line: line, reason: "Weight out of range (\(rawWeight.trimmed))"))
                continue
            }
            result.rows.append(WeightRow(date: date, pounds: pounds, line: line))
        }

        result.rows.sort { $0.date < $1.date }
        return result
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
