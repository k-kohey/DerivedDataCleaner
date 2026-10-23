import Foundation
import Darwin

struct DeletionResult: Identifiable, Sendable {
    var id: URL { directory }
    let directory: URL
    let outcome: Outcome
    var reclaimedBytes: Int64?

    enum Outcome: Equatable, Sendable {
        case deleted
        case skipped(String)
        case failed(String)
    }
}

/// Revalidates each selected snapshot immediately before permanent removal.
/// This reduces races but does not coordinate with Xcode or lock out new builds.
struct DerivedDataDeleter: Sendable {
    var scanner = DerivedDataScanner()
    var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var measure: @Sendable (URL) throws -> Int64 = Self.allocatedBytes

    func delete(_ selected: [ScanEntry], root: URL, policy: ScanPolicy, now: Date = .now) -> [DeletionResult] {
        let root = root.standardizedFileURL
        var processed: Set<String> = []
        // Foundation path standardization can depend on filesystem existence.
        // Normalize the whole selection before the first removal changes it.
        let normalized = selected.map { ($0, $0.directory.standardizedFileURL) }
        return normalized.compactMap { original, directory in
            guard processed.insert(directory.path).inserted else { return nil }
            func result(_ outcome: DeletionResult.Outcome) -> DeletionResult {
                DeletionResult(directory: directory, outcome: outcome)
            }
            guard directory.deletingLastPathComponent().path == root.path,
                  original.isCandidate, original.identity != nil else {
                return result(.skipped("Not a scanned deletion candidate"))
            }
            do {
                // Rescan with the current policy. Never trust a stale UI selection alone.
                let fresh = try scanner.scan(root: root, policy: policy, now: now)
                guard let current = fresh.entries.first(where: { $0.directory.standardizedFileURL.path == directory.path }),
                      current.isCandidate else {
                    return result(.skipped("No longer eligible or already removed"))
                }
                guard current.identity == original.identity,
                      current.workspace == original.workspace,
                      current.lastUsed == original.lastUsed else {
                    return result(.skipped("Changed since the scan. Scan again before deleting."))
                }
                // Measurement failure must not prevent cleanup or pretend to free zero bytes.
                let bytes = try? measure(directory)
                // Reject redirection through a replaced child or ancestor symlink.
                guard directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent).path,
                      try DirectoryIdentity(directory) == original.identity else {
                    return result(.skipped("The folder has been replaced or changed"))
                }
                try remove(directory)
                return DeletionResult(directory: directory, outcome: .deleted, reclaimedBytes: bytes)
            } catch {
                return result(.failed(DisplayText.error(error)))
            }
        }
    }

    /// Estimated allocated size, without following links. Shared hard-linked
    /// files are excluded because unlinking one name need not free their blocks.
    static func allocatedBytes(_ directory: URL) throws -> Int64 {
        var total: Int64 = 0
        func add(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFREG && info.st_nlink > 1 { return }
            total += Int64(info.st_blocks) * 512
        }
        try add(directory)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                              options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in enumerator { try add(url) }
        if let enumerationError { throw enumerationError }
        return total
    }
}
