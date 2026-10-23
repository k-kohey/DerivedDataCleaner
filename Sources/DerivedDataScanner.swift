import Foundation

enum WorkspaceStatus: Sendable, Equatable {
    case present, missing, unavailable
}

enum RemovalReason: String, Sendable, Equatable {
    case missingWorkspace = "Project no longer exists"
    case expired = "Retention period exceeded"
}

struct ScanPolicy: Sendable {
    var retentionDays = 30
    var includeMissingWorkspaces = true
    var excludedWorkspacePaths: Set<String> = []
}

struct ScanEntry: Identifiable, Sendable {
    var id: URL { directory }
    let directory: URL
    let workspace: URL?
    let lastUsed: Date?
    let reasons: [RemovalReason]
    let note: String?
    var identity: DirectoryIdentity?
    var isCandidate: Bool { !reasons.isEmpty }
}

struct DirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let modified: Date

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw DerivedDataScanner.ScanError.invalidRoot
        }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
        self.modified = modified
    }
}

struct ScanReport: Sendable {
    let entries: [ScanEntry]
    let scannedAt: Date
    var candidates: [ScanEntry] { entries.filter(\.isCandidate) }
}

/// Read-only: only immediate, non-symlink child directories are inspected.
struct DerivedDataScanner: Sendable {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    var workspaceStatus: @Sendable (URL) -> WorkspaceStatus = Self.probeWorkspace

    func scan(root: URL, policy: ScanPolicy = .init(), now: Date = .now) throws -> ScanReport {
        guard policy.retentionDays > 0 else { throw ScanError.invalidRetention }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ScanError.invalidRoot
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = now.addingTimeInterval(-Double(policy.retentionDays) * 86_400)
        let entries = children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory -> ScanEntry? in
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                // Shared caches are never project deletion candidates.
                guard !directory.lastPathComponent.hasSuffix(".noindex") else { return nil }
                let identity = try DirectoryIdentity(directory)
                var entry = inspect(directory, policy: policy, cutoff: cutoff)
                guard try DirectoryIdentity(directory) == identity else {
                    return ScanEntry(directory: directory, workspace: nil, lastUsed: nil,
                                     reasons: [], note: "Skipped: changed during scan")
                }
                entry.identity = identity
                return entry
            } catch {
                return ScanEntry(directory: directory, workspace: nil, lastUsed: nil,
                                 reasons: [], note: "Could not read: \(DisplayText.error(error))")
            }
        }
        return ScanReport(entries: entries, scannedAt: now)
    }

    private func inspect(_ directory: URL, policy: ScanPolicy, cutoff: Date) -> ScanEntry {
        var workspace: URL?
        var lastUsed: Date?
        func entry(_ reasons: [RemovalReason] = [], _ note: String? = nil) -> ScanEntry {
            ScanEntry(directory: directory, workspace: workspace, lastUsed: lastUsed, reasons: reasons, note: note)
        }
        do {
            let metadata = try readPlist(directory.appendingPathComponent("info.plist"))
            guard let path = metadata["WorkspacePath"] as? String, path.hasPrefix("/"), path != "/" else {
                return entry([], "Project path is unknown")
            }
            workspace = URL(fileURLWithPath: path).standardizedFileURL
            guard let workspace else { return entry([], "Project path is unknown") }
            if policy.excludedWorkspacePaths.contains(workspace.path) {
                return entry([], "Excluded by user")
            }
            lastUsed = metadata["LastAccessedDate"] as? Date
            let manifest = directory.appendingPathComponent("Logs/Build/LogStoreManifest.plist")
            do {
                let logStore = try readPlist(manifest)
                guard let logs = logStore["logs"] as? [String: [String: Any]] else {
                    return entry([], "Build log format is unknown")
                }
                for log in logs.values {
                    for key in ["timeStartedRecording", "timeStoppedRecording"] {
                        if let seconds = log[key] as? Double, seconds.isFinite, seconds > 0 {
                            let date = Date(timeIntervalSinceReferenceDate: seconds)
                            lastUsed = max(lastUsed ?? date, date)
                        }
                    }
                }
            } catch {
                if !Self.isMissing(error) { return entry([], "Skipped: build logs could not be read") }
            }
            guard let lastUsed, lastUsed.timeIntervalSinceReferenceDate.isFinite else {
                return entry([], "Last used date is unknown")
            }
            let status = workspaceStatus(workspace)
            guard status != .unavailable else { return entry([], "Skipped: project location is unavailable") }
            var reasons: [RemovalReason] = []
            if status == .missing, policy.includeMissingWorkspaces { reasons.append(.missingWorkspace) }
            if lastUsed <= cutoff { reasons.append(.expired) }
            return entry(reasons)
        } catch {
            return entry([], "Skipped: metadata could not be read")
        }
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ScanError.invalidMetadata }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else { throw ScanError.invalidMetadata }
        return dictionary
    }

    static func probeWorkspace(_ url: URL) -> WorkspaceStatus {
        let fm = FileManager.default
        // An unmounted external volume is not a deleted project.
        let components = url.standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "Volumes" {
            let volumePath = "/Volumes/" + components[2]
            guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []),
                  volumes.contains(where: { $0.standardizedFileURL.path == volumePath }) else {
                return .unavailable
            }
        }
        do {
            _ = try fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            return .present
        } catch {
            return isMissing(error) ? .missing : .unavailable
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && [2, 20].contains(error.code))
    }

    enum ScanError: EnglishDescribedError {
        case invalidRoot, invalidRetention, invalidMetadata
        var englishDescription: String {
            switch self {
            case .invalidRoot: "The scan location must be a folder, not a symbolic link."
            case .invalidRetention: "The retention period must be at least one day."
            case .invalidMetadata: "The project metadata is invalid or unavailable."
            }
        }
    }
}
