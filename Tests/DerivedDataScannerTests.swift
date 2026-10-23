import Testing
import Foundation

struct DerivedDataScannerTests {
    private let storage: TemporaryDirectory
    private var root: URL { storage.url }
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() throws { storage = try TemporaryDirectory() }

    @discardableResult
    private func fixture(_ name: String = "App-hash", days: Double = 40, path: String = "/projects/App.xcworkspace") throws -> URL {
        let directory = root.appendingPathComponent(name)
        try write(["WorkspacePath": path, "LastAccessedDate": now.addingTimeInterval(-days * 86_400)],
                  to: directory.appendingPathComponent("info.plist"))
        return directory
    }

    private func write(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }

    private func scan(_ status: WorkspaceStatus = .present, policy: ScanPolicy = .init()) throws -> ScanReport {
        try DerivedDataScanner(workspaceStatus: { _ in status }).scan(root: root, policy: policy, now: now)
    }

    @Test func testRetentionBoundaryAndRecentProject() throws {
        try fixture("old", days: 31)
        try fixture("boundary", days: 30)
        try fixture("recent", days: 29)
        let result = try scan()
        #expect(result.candidates.map { $0.directory.lastPathComponent } == ["boundary", "old"])
        #expect(result.candidates.allSatisfy { $0.reasons == [.expired] })
    }

    @Test func testMissingWorkspaceAndDisabledRule() throws {
        try fixture(days: 1)
        #expect(try scan(.missing).candidates.first?.reasons == [.missingWorkspace])
        #expect(try scan(.missing, policy: .init(includeMissingWorkspaces: false)).candidates.isEmpty)
    }

    @Test func testUnavailableWorkspaceIsNeverCandidateEvenWhenOld() throws {
        try fixture()
        let result = try scan(.unavailable)
        #expect(result.candidates.isEmpty)
        #expect(result.entries.first?.note != nil)
    }

    @Test func testNewBuildLogOverridesOldAccessDateUsingAppleEpoch() throws {
        let directory = try fixture()
        let started = now.addingTimeInterval(-100)
        try write(["logs": ["build": ["timeStartedRecording": started.timeIntervalSinceReferenceDate,
                                       "timeStoppedRecording": now.timeIntervalSinceReferenceDate]]],
                  to: directory.appendingPathComponent("Logs/Build/LogStoreManifest.plist"))
        let result = try scan()
        #expect(result.candidates.isEmpty)
        #expect(result.entries.first?.lastUsed == now)
    }

    @Test func testOldBuildLogDoesNotReplaceNewAccessDate() throws {
        let directory = try fixture(days: 1)
        try write(["logs": ["old": ["timeStoppedRecording": now.addingTimeInterval(-90 * 86_400).timeIntervalSinceReferenceDate]]],
                  to: directory.appendingPathComponent("Logs/Build/LogStoreManifest.plist"))
        #expect(try scan().entries.first?.lastUsed == now.addingTimeInterval(-86_400))
    }

    @Test func testExcludedWorkspace() throws {
        try fixture()
        #expect(try scan(.missing, policy: .init(excludedWorkspacePaths: ["/projects/App.xcworkspace"])).candidates.isEmpty)
    }

    @Test func testMalformedAndMissingMetadataAreReportedButExcluded() throws {
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: bad.appendingPathComponent("info.plist"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("missing"), withIntermediateDirectories: true)
        let result = try scan(.missing)
        #expect(result.entries.count == 2)
        #expect(result.candidates.isEmpty)
        #expect(result.entries.allSatisfy { $0.note != nil })
    }

    @Test func testUnknownDatesAndRelativePathsAreExcluded() throws {
        try write(["WorkspacePath": "/project"], to: root.appendingPathComponent("no-date/info.plist"))
        try fixture("relative", path: "relative/project")
        #expect(try scan(.missing).candidates.isEmpty)
    }

    @Test func testCorruptBuildManifestIsExcluded() throws {
        let directory = try fixture()
        try write(["unexpected": true], to: directory.appendingPathComponent("Logs/Build/LogStoreManifest.plist"))
        #expect(try scan().candidates.isEmpty)
    }

    @Test func testSharedCachesSymlinksAndFilesAreNotEnumeratedAsProjects() throws {
        let directory = try fixture()
        try fixture("ModuleCache.noindex")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: directory)
        try Data().write(to: root.appendingPathComponent("file"))
        let result = try scan()
        #expect(result.entries.map { $0.directory.lastPathComponent } == ["App-hash"])
    }

    @Test func testScanDoesNotModifyMetadata() throws {
        let directory = try fixture()
        let url = directory.appendingPathComponent("info.plist")
        let before = try Data(contentsOf: url)
        _ = try scan(.missing)
        #expect(try Data(contentsOf: url) == before)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func testInvalidRetentionAndMissingRootThrow() throws {
        #expect(throws: (any Error).self) { try scan(policy: .init(retentionDays: 0)) }
        #expect(throws: (any Error).self) { try DerivedDataScanner().scan(root: root.appendingPathComponent("absent")) }
    }

    @Test func testRealWorkspaceProbeDistinguishesPresentMissingAndUnmountedVolume() throws {
        #expect(DerivedDataScanner.probeWorkspace(root) == .present)
        #expect(DerivedDataScanner.probeWorkspace(root.appendingPathComponent("absent")) == .missing)
        #expect(DerivedDataScanner.probeWorkspace(URL(fileURLWithPath: "/Volumes/Unavailable-\(UUID())/App.xcodeproj")) == .unavailable)
    }

    private var deleter: DerivedDataDeleter {
        DerivedDataDeleter(scanner: DerivedDataScanner(workspaceStatus: { _ in .present }))
    }

    @Test func deletionRecordsAllocatedBytesOnlyOnSuccess() throws {
        let target = try fixture()
        try Data(repeating: 42, count: 131_072).write(to: target.appendingPathComponent("product"))
        let expected = try DerivedDataDeleter.allocatedBytes(target)
        #expect(expected > 0)
        let selected = try scan().candidates
        var failing = deleter
        failing.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(failing.delete(selected, root: root, policy: .init(), now: now).first?.reclaimedBytes == nil)
        #expect(deleter.delete(selected, root: root, policy: .init(), now: now).first?.reclaimedBytes == expected)
    }

    @Test func sizeMeasurementDoesNotFollowSymlinksOrCountSharedHardLinks() throws {
        let target = try fixture()
        let external = root.appendingPathComponent("external-file")
        try Data(repeating: 42, count: 131_072).write(to: external)
        let baseline = try DerivedDataDeleter.allocatedBytes(target)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("link"), withDestinationURL: external)
        try FileManager.default.linkItem(at: external, to: target.appendingPathComponent("hard-link"))
        let measured = try DerivedDataDeleter.allocatedBytes(target)
        // Only the tiny link/directory metadata may be added, not the payload.
        #expect(measured >= baseline)
        #expect(measured < baseline + 131_072)
    }

    @Test func unknownSizeDoesNotPreventDeletion() throws {
        let target = try fixture()
        var service = deleter
        service.measure = { _ in throw CocoaError(.fileReadNoPermission) }
        let result = try #require(service.delete(try scan().candidates, root: root, policy: .init(), now: now).first)
        #expect(result.outcome == .deleted)
        #expect(result.reclaimedBytes == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deletionRemovesOnlySelectedCandidateAndItsContents() throws {
        let target = try fixture("selected")
        let unselected = try fixture("unselected")
        let recent = try fixture("recent", days: 1)
        let cache = try fixture("ModuleCache.noindex")
        try write(["payload": true], to: target.appendingPathComponent("Build/Products/dummy.plist"))
        let candidate = try #require(try scan().candidates.first { $0.directory.lastPathComponent == "selected" })
        let results = deleter.delete([candidate], root: root, policy: .init(), now: now)
        #expect(results.map(\.outcome) == [.deleted])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        for retained in [unselected, recent, cache] {
            #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("info.plist").path))
        }
    }

    @Test func deletionSkipsDataAccessedAfterScanEvenIfStillOld() throws {
        let target = try fixture(days: 60)
        let selected = try scan().candidates
        try fixture(days: 45)
        let results = deleter.delete(selected, root: root, policy: .init(), now: now)
        #expect(results.count == 1)
        if case .skipped = results[0].outcome {} else { Issue.record("Changed data must be skipped") }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deletionRechecksPolicyAndExclusions() throws {
        let target = try fixture()
        let selected = try scan().candidates
        let results = deleter.delete(selected, root: root, policy: .init(retentionDays: 90), now: now)
        #expect(results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        let excluded = deleter.delete(selected, root: root, policy: .init(excludedWorkspacePaths: ["/projects/App.xcworkspace"]), now: now)
        #expect(excluded.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deletionRejectsNonCandidatesAndOutsideRoot() throws {
        let target = try fixture(days: 1)
        let entries = try scan().entries
        #expect(deleter.delete(entries, root: root, policy: .init(), now: now).allSatisfy {
            if case .skipped = $0.outcome { true } else { false }
        })
        try fixture(days: 40)
        let selected = try scan().candidates
        #expect(deleter.delete(selected, root: root.appendingPathComponent("other"), policy: .init(), now: now).allSatisfy {
            if case .skipped = $0.outcome { true } else { false }
        })
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deletionRejectsFolderReplacedBySymlink() throws {
        let target = try fixture("target")
        let retained = try fixture("retained")
        let selected = try scan().candidates.filter { $0.directory.lastPathComponent == "target" }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: retained)
        let results = deleter.delete(selected, root: root, policy: .init(), now: now)
        #expect(results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("info.plist").path))
    }

    @Test func deletionRejectsReplacementDirectoryWithSameMetadata() throws {
        let target = try fixture()
        let selected = try scan().candidates
        // Keep the old inode alive so replacement cannot reuse it.
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("original"))
        try fixture()
        let results = deleter.delete(selected, root: root, policy: .init(), now: now)
        #expect(results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deletingInternalSymlinkDoesNotDeleteItsDestination() throws {
        let target = try fixture("target")
        let retained = try fixture("retained")
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("linked-product"), withDestinationURL: retained)
        let selected = try scan().candidates.filter { $0.directory.lastPathComponent == "target" }
        #expect(deleter.delete(selected, root: root, policy: .init(), now: now).map(\.outcome) == [.deleted])
        #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("info.plist").path))
    }

    @Test func deletionReportsFailureAndContinuesWithOtherCandidates() throws {
        let denied = try fixture("denied")
        let allowed = try fixture("allowed")
        var service = deleter
        service.remove = { url in
            if url.lastPathComponent == "denied" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let results = service.delete(try scan().candidates.sorted { $0.directory.path > $1.directory.path }, root: root, policy: .init(), now: now)
        #expect(results.count == 2)
        if case .failed = results[0].outcome {} else { Issue.record("Expected a reported removal failure") }
        #expect(results[1].outcome == .deleted)
        #expect(FileManager.default.fileExists(atPath: denied.path))
        #expect(!FileManager.default.fileExists(atPath: allowed.path))
    }

    @Test func deletionDeduplicatesAndHandlesAlreadyDeletedEntries() throws {
        try fixture()
        let selected = try scan().candidates
        #expect(deleter.delete(selected + selected, root: root, policy: .init(), now: now).map(\.outcome) == [.deleted])
        let repeated = deleter.delete(selected, root: root, policy: .init(), now: now)
        #expect(repeated.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
    }

    @Test func deletionRechecksWorkspaceAvailability() throws {
        let target = try fixture()
        let selected = try scan().candidates
        let service = DerivedDataDeleter(scanner: DerivedDataScanner(workspaceStatus: { _ in .unavailable }))
        #expect(service.delete(selected, root: root, policy: .init(), now: now).allSatisfy {
            if case .skipped = $0.outcome { true } else { false }
        })
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}

private final class TemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
