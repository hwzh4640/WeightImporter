import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var showingImporter = false
    @State private var fileName: String?
    @State private var parse = ParseResult()
    @State private var overwrite = false
    @State private var isRunning = false
    @State private var report: ImportReport?
    @State private var errorMessage: String?
    @State private var showIssues = false
    @State private var showLog = false

    private let engine = ImportEngine()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd h:mm a"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                fileSection
                if !parse.rows.isEmpty || !parse.issues.isEmpty { previewSection }
                optionsSection
                importSection
                if let report { resultSection(report) }
            }
            .navigationTitle("Weight Importer")
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.commaSeparatedText, .text, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                handlePick(result)
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var fileSection: some View {
        Section("File") {
            Button {
                showingImporter = true
            } label: {
                Label(fileName == nil ? "Choose CSV…" : "Choose a different CSV…",
                      systemImage: "doc.badge.plus")
            }
            if let fileName {
                LabeledContent("Loaded", value: fileName)
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            LabeledContent("Rows", value: "\(parse.rows.count)")
            if let first = parse.rows.first, let last = parse.rows.last {
                LabeledContent("Range",
                               value: "\(Self.display.string(from: first.date)) → \(Self.display.string(from: last.date))")
            }
            if let h = parse.detectedWeightHeader {
                LabeledContent("Weight column", value: h)
            }
            if let h = parse.detectedDateHeader {
                LabeledContent("Date column", value: h)
            }
            LabeledContent("Separator", value: separatorLabel(parse.delimiter))
            if parse.convertedFromKilograms {
                Text("Values look like kilograms and are being converted to pounds.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ForEach(parse.rows.prefix(5)) { row in
                HStack {
                    Text(Self.display.string(from: row.date))
                    Spacer()
                    Text(String(format: "%.1f lb", row.pounds))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.footnote)
            }
            if parse.rows.count > 5 {
                Text("…and \(parse.rows.count - 5) more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !parse.issues.isEmpty {
                DisclosureGroup(isExpanded: $showIssues) {
                    ForEach(parse.issues) { issue in
                        Text("Line \(issue.line): \(issue.reason)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("\(parse.issues.count) row(s) couldn’t be read",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Overwrite entries at the same time", isOn: $overwrite)
        } footer: {
            Text("Off: a row is skipped when Health already has a weight entry at that exact minute. On: entries this app wrote at that minute are replaced. Entries from the Health app or other apps can never be deleted, so the CSV value is added alongside them. A row at a new time on a day that already has entries is always added either way.")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                runImport()
            } label: {
                HStack {
                    if isRunning { ProgressView().padding(.trailing, 4) }
                    Text(isRunning ? "Importing…" : "Import \(parse.rows.count) entries")
                }
            }
            .disabled(parse.rows.isEmpty || isRunning)
        }
    }

    private func resultSection(_ report: ImportReport) -> some View {
        Section("Result") {
            LabeledContent("Existing entries found", value: "\(report.existingFound)")
            LabeledContent("Written", value: "\(report.written)")
            LabeledContent("Skipped", value: "\(report.skipped)")
            LabeledContent("Overwritten", value: "\(report.overwritten)")
            if report.duplicatesCollapsed > 0 {
                LabeledContent("Duplicate rows collapsed", value: "\(report.duplicatesCollapsed)")
            }
            LabeledContent("Failed", value: "\(report.failed.count)")

            if report.existingFound == 0 && report.skipped == 0 {
                Text("No existing entries were seen. If Health already has weight data for this period, read access was probably denied — check Settings → Health → Data Access & Devices → WeightImporter.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Log", isExpanded: $showLog) {
                ForEach(Array(report.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(report.failed) { issue in
                    Text("Line \(issue.line): \(issue.reason)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func separatorLabel(_ d: Character) -> String {
        switch d {
        case "\t": return "tab"
        case ";": return "semicolon"
        case "|": return "pipe"
        default: return "comma"
        }
    }

    // MARK: - Actions

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text: String
                if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                    text = utf8
                } else {
                    text = try String(contentsOf: url, encoding: .isoLatin1)
                }
                parse = CSVParser.parse(text)
                fileName = url.lastPathComponent
                report = nil
                if parse.rows.isEmpty {
                    errorMessage = parse.issues.first?.reason ?? "No usable rows found in that file."
                }
            } catch {
                errorMessage = "Couldn’t read the file: \(error.localizedDescription)"
            }
        }
    }

    private func runImport() {
        isRunning = true
        report = nil
        let rows = parse.rows
        let issues = parse.issues
        let overwriteNow = overwrite
        Task {
            do {
                let result = try await engine.run(rows: rows, issues: issues, overwrite: overwriteNow)
                await MainActor.run {
                    report = result
                    showLog = true
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
