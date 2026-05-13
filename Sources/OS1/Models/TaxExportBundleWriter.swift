import Foundation

/// Writes a `TaxExportBundle` to disk in the layout documented in
/// `docs/tax-export.md`:
///
/// ```
/// <root>/<entityID>__<jurisdiction>__<taxYear>/
///   ├── pl.csv
///   ├── revenue_register.csv
///   ├── expense_register.csv
///   ├── irs_line_items.csv          (US-FED only)
///   ├── 1099_register.csv           (US-FED only)
///   ├── sales_tax_summary.csv       (US-CA only)
///   ├── quarterly_estimates.csv     (US-FED / US-CA)
///   └── manifest.json
/// ```
///
/// Writes are atomic (per file) and the directory is created on demand so
/// the in-app Tax tab can persist directly into the user-selected location.
enum TaxExportBundleWriter {
    struct Output: Equatable {
        var directory: URL
        var filePaths: [String]
    }

    static func write(_ bundle: TaxExportBundle, to root: URL) throws -> Output {
        let dirName = "\(bundle.entityID)__\(bundle.jurisdiction)__\(bundle.taxYear)"
        let directory = root.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        for file in bundle.files.sorted(by: { $0.path < $1.path }) {
            let url = directory.appendingPathComponent(file.path)
            try file.bytes.write(to: url, options: .atomic)
            paths.append(file.path)
        }
        return Output(directory: directory, filePaths: paths)
    }

    /// Convenience: write every bundle in a request's result set under a
    /// shared root directory (one sub-folder per bundle).
    static func write(_ bundles: [TaxExportBundle], to root: URL) throws -> [Output] {
        try bundles.map { try write($0, to: root) }
    }
}
