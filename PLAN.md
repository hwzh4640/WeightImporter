# Plan: WeightImporter — CSV → Apple Health body-mass importer (iOS)

> This is the original design document the app was built from, kept for reference.
> Where the implementation diverged, see **Deviations from this plan** at the end.

## Context

Historical weight data lives in a CSV (`lbs` like `125.5`, date like `"2020-02-25, 7:32AM"`)
and needs to go into Apple Health. Nothing off-the-shelf does the "skip days that already
have data" rule cleanly, so this is a single-screen SwiftUI app that:

1. Lets you pick the CSV from Files.
2. Parses and previews the rows.
3. Writes each row as a HealthKit body-mass sample. The CSV can have **several entries per
   day at different times, and all of them are imported**. A row is **skipped only if Health
   already has a body-mass sample (from any source) at the same minute** as that row.
4. Has an **Overwrite** toggle (default OFF). When ON, for a row whose minute already has
   data, the app deletes samples *it wrote itself* at that minute and then writes the CSV
   value. HealthKit never allows deleting other apps' or manually entered samples, so those
   get the CSV value *added alongside* the existing one.

Decisions confirmed up front:

- CSV date is a single quoted column containing `date, time`.
- Multiple rows per day are normal and must all be written.
- Skip check is per-minute (row time truncated to the minute), considering samples from any
  source. "Same day" alone does not cause a skip.
- Overwrite = delete own samples at that minute, then write.

## Running without a paid developer account

Works with a free Apple ID ("Personal Team"):

1. Xcode → Settings → Accounts → add your Apple ID.
2. Signing & Capabilities → Team = your name (Personal Team), "Automatically manage
   signing" checked. Bundle ID must be unique, e.g. `com.example.WeightImporter`.
3. Add the **HealthKit** capability (allowed on Personal Team).
4. iPhone: Settings → Privacy & Security → Developer Mode → on (reboot). Plug in via USB,
   trust the Mac.
5. Select the iPhone as run destination, press Run. First launch: Settings → General →
   VPN & Device Management → trust your Apple ID.

Limits: the provisioning profile expires after 7 days (re-run from Xcode to refresh), max 3
sideloaded apps, 10 new bundle IDs per week. None matter for a one-shot import.

## Project setup

- Xcode 15+ (16 preferred), new project → iOS → App, Interface SwiftUI, Language Swift,
  no tests. Deployment target iOS 17.
- Signing & Capabilities → `+ Capability` → HealthKit (do **not** tick "Clinical Health
  Records" or "Background Delivery").
- Info tab, add two keys (both required or the app crashes on authorization):
  - `NSHealthShareUsageDescription` — why the app reads existing entries.
  - `NSHealthUpdateUsageDescription` — why the app writes entries.

## Files

### `WeightImporterApp.swift`
Standard `@main` App struct showing `ContentView`.

### `CSVParser.swift`
- RFC-4180-style tokenizer: handles quoted fields, `""` escapes, delimiters inside quotes,
  `\r\n`/`\n`. Do not use `split(separator: ",")` — the date field contains a comma.
- Header detection: first row is a header if no cell parses as a number. Pick the weight
  column as the header containing `lb`/`weight`/`mass` (case-insensitive), else the first
  column whose values parse as Double. Pick the date column as the header containing
  `date`/`time`, else the first column whose values parse as a Date.
- Date parsing with `DateFormatter`, `locale = en_US_POSIX`, `timeZone = .current`, trying
  `yyyy-MM-dd, h:mma` (matches `2020-02-25, 7:32AM`), `yyyy-MM-dd, h:mm a`,
  `yyyy-MM-dd h:mma`, `yyyy-MM-dd HH:mm`, `M/d/yyyy h:mm a`, `M/d/yyyy`, and `yyyy-MM-dd`
  (time defaults to 12:00 so it stays on the same day in any zone). Also strip narrow
  no-break spaces (`\u{202F}`) that Apple Numbers exports before AM/PM.
- Output: `[WeightRow]` where `struct WeightRow { let date: Date; let pounds: Double; let line: Int }`
  plus `[ParseIssue]` for rows that fail (line number + reason). Rows with pounds ≤ 0 or
  > 1500 are rejected.

### `HealthKitManager.swift`
- `requestAuthorization()` — guards `isHealthDataAvailable()`, requests share+read on
  `bodyMass`.
- `minuteKey(_:)` — sample start time truncated to the minute (epoch seconds / 60). Keys are
  absolute (UTC epoch minutes), so time-zone choice only matters when the parser interprets
  the CSV string. The parser uses the device zone.
- `existingMinutes(from:to:)` — one `HKSampleQuery` over the whole date span; returns the set
  of minutes that have ANY body-mass sample, plus this app's own samples grouped by minute
  (matched via `HKSource.default()`), which are the only ones that may be deleted.
- `delete(_:)` / `save(_:)`.

**Read-permission caveat:** HealthKit hides read denials. If read access is denied, the query
returns nothing, every day looks empty, and nothing is skipped. The UI should surface an
"Existing entries found: N" line so this is visible.

### `ImportEngine.swift`
Pure orchestration, returns an `ImportReport` with `written` / `skipped` / `overwritten` /
`failed` / `log`.

1. `requestAuthorization()`.
2. Compute `[minDate - 1 day, maxDate + 1 day]` from parsed rows, call `existingMinutes`.
3. For each row, `k = minuteKey(row.date)`:
   - `k` not in `anySource` → write.
   - `k` in `anySource`, overwrite OFF → skip (log `"2020-02-25 7:32 AM skipped: existing entry"`).
   - `k` in `anySource`, overwrite ON → if `own[k]` non-empty, delete those first and count as
     overwritten; then write. If that minute only has other-source samples, log that the CSV
     value was added alongside.
4. Multiple CSV rows on the same day at different times are all written; they are judged only
   against HealthKit, not each other. Exact duplicate rows inside the CSV (same minute, same
   value) are collapsed to one before import and reported in the log.
5. One `save([...])` call for all rows to write; on failure fall back to saving in chunks of
   200 so one bad row doesn't sink the batch.
6. Never re-throw for per-row problems; only for auth/HealthKit-unavailable.

### `ContentView.swift`
Single `Form`:

- **File**: "Choose CSV…" → `.fileImporter`. Wrap in
  `url.startAccessingSecurityScopedResource()` / `stopAccessing…`, read with
  `String(contentsOf:encoding: .utf8)` (fallback `.isoLatin1`).
- **Preview**: row count, date range, first 5 rows, parse issue count (tap to expand).
- **Options**: `Toggle("Overwrite entries at the same time")` default `false`, with a footer
  explaining that only entries written by this app can be replaced, and that entries at new
  times on an existing day are always added.
- **Import** button (disabled until rows parsed), `ProgressView` while running, then a
  summary: written / skipped / overwritten / failed, plus a scrollable log.
- Errors surface in an `.alert`.

Everything HealthKit-related runs off the main actor; UI state updates on `@MainActor`.

## Verification

1. **Simulator first** (HealthKit works there). `sample.csv`:
   ```
   Date,Weight (lb)
   "2020-02-25, 7:32AM",125.5
   "2020-02-25, 9:15PM",126.3
   "2020-02-26, 7:40AM",125.1
   "2020-02-27, 7:35AM",124.8
   ```
   Confirm the preview shows 4 rows with the right times.
2. Import → grant read and write → expect written=4. Check Health shows two entries on 02-25
   (7:32 AM and 9:15 PM) plus one each on 02-26 and 02-27.
3. Import again with overwrite OFF → expect skipped=4, written=0.
4. Add `"2020-02-25, 12:00PM",126.0`, import with overwrite OFF → expect written=1,
   skipped=4 (a new time on an existing day is added).
5. Manually add a weight in Health at a CSV row's minute, import with overwrite ON → own
   samples replaced; log notes the other source; Health shows both values at that minute.
6. Edge cases: a row with a bad date and a row with `abc` weight appear in the failed list,
   others still import. A CSV with `\r\n` endings and a BOM parses the same.
7. Then run on the real iPhone with the real CSV. Before importing, confirm "Existing entries
   found" matches what Health shows for that span (proves read permission was granted).

## Out of scope

- Background sync, iCloud, Watch.

---

## Deviations from this plan

Changes made during implementation, and why:

1. **Delimiter auto-detection.** The plan assumed comma-separated files. The real export was
   semicolon-separated with an unquoted comma *inside* the date field
   (`132.0; 2017-09-22, 11:19 AM; HealthKit`), which comma splitting destroys. The parser now
   sniffs `,` `;` tab `|` by whichever yields the most consistent column layout, and the
   preview shows which it chose.

2. **Kilogram support.** Listed as out of scope, but the parser already reads the header to
   locate the weight column, so a `kg` header (without `lb`) now converts to pounds and says
   so in the preview. Silently importing kilograms as pounds is the worse failure.

3. **`requestAuthorization` checks its result.** The planned version returns successfully even
   when the user denies write access, so an import would report success having written
   nothing. It now throws `ImportError.authorizationDenied`. Read denials still cannot be
   detected — HealthKit deliberately hides them — which is what the "Existing entries found"
   line is for.

4. **File sharing enabled.** `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` were
   added so the app's Documents folder appears in Files under *On My iPhone → WeightImporter*
   and in Finder over USB. Without this there is no straightforward way to get a CSV onto a
   sideloaded app.

5. **Signing settings moved to `Config.xcconfig`** (gitignored) so the repository carries no
   Team ID or personal bundle identifier.

## Bugs found during verification

- **CRLF files parsed as zero rows.** Swift treats `"\r\n"` as a *single* `Character`, so
  `c == "\r"` and `c == "\n"` both missed it. Fixed by testing `c.isNewline`.
- **BOM survived stripping.** Grapheme clustering can hide a BOM behind the first visible
  character, corrupting the first header cell. Fixed by stripping at the Unicode-scalar level.
