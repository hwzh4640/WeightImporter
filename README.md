# WeightImporter

Single-screen iOS app that imports a CSV of body weights into Apple Health.

## The rule

- Every CSV row becomes a HealthKit body-mass sample. Several entries per day at
  different times are all imported.
- A row is **skipped** only when Health already has a body-mass sample **from any
  source at the same minute**. Same day alone never causes a skip.
- **Overwrite** (default off): for a row whose minute already has data, samples
  *this app wrote* at that minute are deleted and the CSV value written. HealthKit
  never allows deleting other apps' or manually-entered samples, so those get the
  CSV value added alongside — the log says so when it happens.

Minute keys are absolute (UTC epoch minutes); the time zone matters only when the
parser interprets the CSV text, and it uses the device zone.

## First run (free Apple ID works)

1. Open `WeightImporter.xcodeproj`.
2. Copy the signing config and fill in your own values:

   ```
   cp Config.example.xcconfig Config.xcconfig
   ```

   Set `APP_DEVELOPMENT_TEAM` to your 10-character Apple Developer Team ID and
   `APP_BUNDLE_ID` to your own reverse-DNS identifier. `Config.xcconfig` is
   gitignored, so your Team ID never lands in the repository.
3. HealthKit capability and both usage-description strings are already configured.
4. Simulator: just press Run. Real iPhone: enable Settings → Privacy & Security →
   Developer Mode, plug in, trust the Mac, then run and trust the profile under
   Settings → General → VPN & Device Management.

Personal Team profiles expire after 7 days — re-run from Xcode to refresh.

## Reading a CSV

- The field separator is auto-detected: comma, semicolon, tab or pipe, whichever
  gives the most consistent column layout. The preview shows which one was chosen.
  This matters because semicolon exports often carry an unquoted comma inside the
  date field (`132.0; 2017-09-22, 11:19 AM; HealthKit`).
- Date and weight columns are detected from the header (`date`/`time`, and
  `lb`/`weight`/`mass`/`kg`), falling back to content sniffing when there is no
  header. **Column order does not matter** and extra columns are ignored.
- A `kg` header (without `lb`) converts to pounds and says so in the preview.
- Handles quoted fields, `""` escapes, commas and newlines inside quotes, CRLF,
  a UTF-8 BOM, and the narrow no-break space Apple Numbers puts before AM/PM.
- Rows at or below 0 lb or above 1500 lb are rejected and listed as issues.

## Read-permission caveat

HealthKit hides read denials: deny read access and the query returns nothing,
every minute looks free, and nothing is skipped. The result panel shows
**Existing entries found** for exactly this reason — if Health visibly has weight
data for the span and that number is 0, read access was denied. Fix it in
Settings → Health → Data Access & Devices → WeightImporter.

## Getting the CSV in

`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are set, so the
app's Documents folder shows up in Files under **On My iPhone → WeightImporter**
(and in Finder when the phone is plugged in). Drop the CSV there, or pick it from
iCloud Drive / anywhere else the file picker can reach.

## Test files

- `sample.csv` — the happy path: four rows, two of them on 2020-02-25 at
  different times.
- `sample-edge.csv` — everything at once: two times on one day, a third time
  added mid-day, an exact duplicate row, an unparseable date, and a
  non-numeric weight.

Copy them into the app's Documents folder:

```
xcrun simctl install "iPhone 17 Pro" /path/to/WeightImporter.app
cp sample.csv "$(xcrun simctl get_app_container "iPhone 17 Pro" $APP_BUNDLE_ID data)/Documents/"
```

## Design notes

[PLAN.md](PLAN.md) is the original design document, with a record of where the
implementation diverged from it and which bugs verification turned up.
