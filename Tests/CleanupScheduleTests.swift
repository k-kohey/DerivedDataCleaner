import Foundation
import Testing
import ServiceManagement

struct CleanupScheduleTests {
    private let temporary: ScheduleTestDirectory
    private var store: ScheduleStore { ScheduleStore(directory: temporary.url.appendingPathComponent("settings")) }
    private var root: URL { temporary.url.appendingPathComponent("DerivedData", isDirectory: true) }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }
    init() throws { temporary = try ScheduleTestDirectory() }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func enabled() -> CleanupSettings {
        var settings = CleanupSettings()
        settings.enabled = true
        settings.effectiveFrom = date("2026-10-19T00:00:00+09:00")
        return settings
    }
    private func makeData() throws -> URL {
        let workspace = temporary.url.appendingPathComponent("Project.xcodeproj")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Project-hash")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let plist: [String: Any] = ["WorkspacePath": workspace.path, "LastAccessedDate": date("2025-01-01T00:00:00Z")]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: project.appendingPathComponent("info.plist"))
        return project
    }

    @Test func dailyAndWeeklyDates() {
        var settings = enabled()
        #expect(settings.nextDate(after: date("2026-10-19T01:59:00+09:00"), calendar: calendar) == date("2026-10-19T02:00:00+09:00"))
        #expect(settings.nextDate(after: date("2026-10-19T02:00:00+09:00"), calendar: calendar) == date("2026-10-20T02:00:00+09:00"))
        settings.frequency = .weekly
        settings.weekday = 1
        settings.minute = 15
        #expect(settings.nextDate(after: settings.effectiveFrom, calendar: calendar) == date("2026-10-25T02:15:00+09:00"))
        #expect(settings.nextDate(after: date("2026-10-25T02:15:00+09:00"), calendar: calendar) == date("2026-11-01T02:15:00+09:00"))
    }

    @Test func daylightSavingTransitions() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var settings = enabled()
        settings.minute = 30
        #expect(settings.nextDate(after: date("2026-03-08T00:00:00-08:00"), calendar: cal) == date("2026-03-08T03:00:00-07:00"))
        settings.hour = 1
        let first = date("2026-11-01T01:30:00-07:00")
        #expect(settings.nextDate(after: date("2026-11-01T00:00:00-07:00"), calendar: cal) == first)
        #expect(settings.nextDate(after: first, calendar: cal) == date("2026-11-02T01:30:00-08:00"))
    }

    @Test func settingsRoundTripAndInvalidDataFailClosed() throws {
        #expect(try store.loadSettings().enabled == false)
        let settings = enabled()
        try store.saveSettings(settings)
        #expect(try store.loadSettings() == settings)
        var invalid = settings
        invalid.hour = 24
        #expect(throws: (any Error).self) { try store.saveSettings(invalid) }
        try Data("broken".utf8).write(to: store.directory.appendingPathComponent("settings.json"))
        #expect(throws: (any Error).self) { try store.loadSettings() }
    }

    @Test func settingsAndHistoryArePrivateToTheCurrentUser() throws {
        try store.saveSettings(enabled())
        try store.saveState(ScheduleState(lastRun: ScheduledRun(startedAt: .now, messages: ["Fixture-hash: failed"])))
        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try permissions(store.directory) == 0o700)
        for name in ["settings.json", "state.json"] {
            #expect(try permissions(store.directory.appendingPathComponent(name)) == 0o600)
        }
        // Upgrade permissions from earlier versions when loading existing data.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
        let file = store.directory.appendingPathComponent("state.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = try store.loadState()
        #expect(try permissions(store.directory) == 0o700)
        #expect(try permissions(file) == 0o600)
    }

    @Test func settingsRejectSymbolicLinksAndHardLinks() throws {
        try store.prepare()
        let outside = temporary.url.appendingPathComponent("outside.json")
        let data = try JSONEncoder().encode(enabled())
        try data.write(to: outside)
        let link = store.directory.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try store.loadSettings() }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: outside, to: link)
        #expect(throws: (any Error).self) { try store.loadSettings() }
        #expect(try Data(contentsOf: outside) == data)
    }

    @Test func settingsRejectLinkedDirectoriesAndOversizedFiles() throws {
        let outside = temporary.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = temporary.url.appendingPathComponent("linked-settings")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ScheduleStore(directory: link).loadSettings() }
        try store.prepare()
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1)
            .write(to: store.directory.appendingPathComponent("settings.json"))
        #expect(throws: (any Error).self) { try store.loadSettings() }
    }

    @Test func disabledAndBeforeDeadlineNeverDelete() throws {
        let project = try makeData()
        let runner = ScheduledCleanupRunner(store: store, root: root)
        #expect(try runner.runIfDue(now: date("2026-10-19T04:00:00+09:00"), calendar: calendar) == nil)
        try store.saveSettings(enabled())
        #expect(try runner.runIfDue(now: date("2026-10-19T01:59:59+09:00"), calendar: calendar) == nil)
        #expect(FileManager.default.fileExists(atPath: project.path))
    }

    @Test func dueRunDeletesFixtureAndPersistsAcrossRestart() throws {
        let project = try makeData()
        try store.saveSettings(enabled())
        let now = date("2026-10-19T02:00:00+09:00")
        let result = try ScheduledCleanupRunner(store: store, root: root).runIfDue(now: now, calendar: calendar)
        #expect(result?.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: project.path))
        #expect(try store.loadState().lastRun == result)
        #expect(try ScheduledCleanupRunner(store: store, root: root).runIfDue(now: now, calendar: calendar) == nil)
    }

    @Test func successfulRunPersistsBytesAndSurvivesLaterFailure() throws {
        _ = try makeData()
        try store.saveSettings(enabled())
        var remover = DerivedDataDeleter()
        remover.measure = { _ in 4096 }
        let runner = ScheduledCleanupRunner(store: store, root: root, deleter: remover)
        let success = try #require(try runner.runIfDue(now: date("2026-10-19T02:00:00+09:00"), calendar: calendar))
        #expect(success.reclaimedBytes == 4096)
        #expect(try store.loadState().latestSuccess == success)
        _ = try makeData()
        remover.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        let failure = try ScheduledCleanupRunner(store: store, root: root, deleter: remover)
            .runIfDue(now: date("2026-10-20T02:00:00+09:00"), calendar: calendar)
        #expect(failure?.failed == 1)
        #expect(failure?.reclaimedBytes == 0)
        #expect(try store.loadState().lastRun == failure)
        #expect(try store.loadState().latestSuccess == success)
    }

    @Test func noCandidatesIsSuccessfulWithZeroBytes() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try store.saveSettings(enabled())
        let run = try ScheduledCleanupRunner(store: store, root: root).runIfDue(now: date("2026-10-19T02:00:00+09:00"), calendar: calendar)
        #expect(run?.reclaimedBytes == 0)
        #expect(run?.succeeded == true)
        #expect(try store.loadState().latestSuccess == run)
    }

    @Test func unknownMeasurementRemainsUnknownInHistory() throws {
        _ = try makeData()
        try store.saveSettings(enabled())
        var remover = DerivedDataDeleter()
        remover.measure = { _ in throw CocoaError(.fileReadNoPermission) }
        let run = try ScheduledCleanupRunner(store: store, root: root, deleter: remover)
            .runIfDue(now: date("2026-10-19T02:00:00+09:00"), calendar: calendar)
        #expect(run?.deleted == 1)
        #expect(run?.reclaimedBytes == nil)
        #expect(try store.loadState().latestSuccess == run)
    }

    @Test func previousHistoryWithoutCapacityStillLoads() throws {
        let run = ScheduledRun(startedAt: date("2026-10-19T02:00:00+09:00"), finishedAt: date("2026-10-19T02:01:00+09:00"), deleted: 2)
        try store.prepare()
        // Original history format: no capacity or lastSuccessfulRun keys.
        let data = try JSONEncoder().encode(ScheduleState(lastRun: run))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["lastSuccessfulRun"] == nil)
        try data.write(to: store.directory.appendingPathComponent("state.json"))
        let restored = try store.loadState()
        #expect(restored.latestSuccess == run)
        #expect(restored.latestSuccess?.reclaimedBytes == nil)
    }

    @Test func missedDaysCoalesceIntoOneRun() throws {
        _ = try makeData()
        let settings = enabled()
        try store.saveSettings(settings)
        let wake = date("2026-10-23T09:00:00+09:00")
        let runner = ScheduledCleanupRunner(store: store, root: root)
        #expect(try runner.runIfDue(now: wake, calendar: calendar)?.deleted == 1)
        #expect(try runner.runIfDue(now: wake.addingTimeInterval(60), calendar: calendar) == nil)
        #expect(try store.loadState().nextDate(for: settings, calendar: calendar) == date("2026-10-24T02:00:00+09:00"))
    }

    @Test func failedScanIsRecordedAndNotImmediatelyRetried() throws {
        try store.saveSettings(enabled())
        let runner = ScheduledCleanupRunner(store: store, root: root)
        let now = date("2026-10-19T02:00:00+09:00")
        #expect(try runner.runIfDue(now: now, calendar: calendar)?.failed == 1)
        #expect(try runner.runIfDue(now: now.addingTimeInterval(10), calendar: calendar) == nil)
    }

    @Test func interruptedRunClaimPreventsReplay() throws {
        let project = try makeData()
        let settings = enabled()
        try store.saveSettings(settings)
        let now = date("2026-10-19T02:00:00+09:00")
        try store.saveState(ScheduleState(revision: settings.revision, lastAttempt: now, lastRun: ScheduledRun(startedAt: now)))
        #expect(try ScheduledCleanupRunner(store: store, root: root).runIfDue(now: now.addingTimeInterval(300), calendar: calendar) == nil)
        #expect(FileManager.default.fileExists(atPath: project.path))
    }

    @Test func lockPreventsConcurrentExecution() throws {
        let project = try makeData()
        try store.saveSettings(enabled())
        _ = try store.withLock {
            #expect(throws: (any Error).self) {
                try ScheduledCleanupRunner(store: store, root: root).runIfDue(now: date("2026-10-19T02:00:00+09:00"), calendar: calendar)
            }
        }
        #expect(FileManager.default.fileExists(atPath: project.path))
    }

    @Test @MainActor func registrationFailureLeavesAutomationDisabled() async throws {
        let service = FakeScheduleService()
        service.failRegistration = true
        await #expect(throws: (any Error).self) {
            try await ScheduleController(store: store, service: service).save(enabled())
        }
        #expect(try store.loadSettings().enabled == false)
    }

    @Test @MainActor func enableAndDisableRegisterAndPersist() async throws {
        let service = FakeScheduleService()
        let controller = ScheduleController(store: store, service: service)
        let now = date("2026-10-19T03:00:00+09:00")
        try await controller.save(enabled(), now: now)
        let settings = try store.loadSettings()
        #expect(service.registrations == 1)
        #expect(settings.enabled)
        #expect(settings.effectiveFrom == now)
        #expect(ScheduleState().nextDate(for: settings, calendar: calendar) == date("2026-10-20T02:00:00+09:00"))
        var off = settings
        off.enabled = false
        try await controller.save(off, now: now)
        #expect(service.unregistrations == 1)
        #expect(try store.loadSettings().enabled == false)
    }

    @Test @MainActor func pendingApprovalDoesNotPretendToBeRegistered() async throws {
        let service = FakeScheduleService()
        service.status = .requiresApproval
        try await ScheduleController(store: store, service: service).save(enabled())
        #expect(service.registrations == 0)
        #expect(service.status == .requiresApproval)
        #expect(try store.loadSettings().enabled)
    }

    @Test func bundledHelperExecutesOnlyAgainstTemporaryData() throws {
        let project = try makeData()
        var settings = enabled()
        settings.effectiveFrom = Date.now.addingTimeInterval(-3 * 86_400)
        try store.saveSettings(settings)
        let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        let app = products.appendingPathComponent("DerivedDataCleaner.app")
        let helper = app.appendingPathComponent("Contents/MacOS/DerivedDataCleanerScheduler")
        let plistURL = app.appendingPathComponent("Contents/Library/LaunchAgents/dev.kohey.DerivedDataCleaner.scheduler.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/DerivedDataCleanerScheduler")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--run-once", store.directory.path, root.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: project.path))
        #expect(try store.loadState().lastRun?.deleted == 1)
    }

    @Test func runningHelperReloadsChangedSettingsWithoutApp() throws {
        let project = try makeData()
        var settings = enabled()
        settings.effectiveFrom = Date.now.addingTimeInterval(-3 * 86_400)
        try store.saveSettings(settings)
        let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = products.appendingPathComponent("DerivedDataCleaner.app/Contents/MacOS/DerivedDataCleanerScheduler")
        process.arguments = ["--serve", store.directory.path, root.path]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        // Bounded wait for the real helper to complete its first run.
        func waitForRun(_ revision: UUID) throws {
            let deadline = Date.now.addingTimeInterval(10)
            while Date.now < deadline {
                let state = try store.loadState()
                if state.revision == revision, state.lastRun?.finishedAt != nil { return }
                guard process.isRunning else { Issue.record("Helper exited prematurely"); return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            Issue.record("Helper did not observe settings before timeout")
        }
        try waitForRun(settings.revision)
        #expect(!FileManager.default.fileExists(atPath: project.path))
        _ = try makeData()
        settings.revision = UUID()
        try store.withLock { try store.saveSettings(settings) }
        try waitForRun(settings.revision)
        #expect(!FileManager.default.fileExists(atPath: project.path))
        #expect(try store.loadState().lastRun?.deleted == 1)
    }
}

private final class BundleMarker: NSObject {}

@MainActor private final class FakeScheduleService: ScheduleService {
    var status = SMAppService.Status.notRegistered
    var failRegistration = false
    var failUnregistration = false
    var statusAfterRegistration = SMAppService.Status.enabled
    var registrations = 0
    var unregistrations = 0
    func register() throws {
        registrations += 1
        if failRegistration { throw CocoaError(.fileWriteNoPermission) }
        status = statusAfterRegistration
    }
    func unregister() async throws {
        unregistrations += 1
        if failUnregistration { throw CocoaError(.fileWriteNoPermission) }
        status = .notRegistered
    }
}

extension CleanupScheduleTests {
    @Test func launchDestinationDistinguishesManualAndLoginLaunches() {
        #expect(OnboardingGate.launchDestination(needsSetup: false, launchedAtLogin: false) == .settings)
        #expect(OnboardingGate.launchDestination(needsSetup: false, launchedAtLogin: true) == .menuBar)
        #expect(OnboardingGate.launchDestination(needsSetup: true, launchedAtLogin: false) == .setup)
        #expect(OnboardingGate.launchDestination(needsSetup: true, launchedAtLogin: true) == .setup)
    }
    @Test func onboardingAppearsUnlessBothFeaturesAreEnabled() {
        var settings = enabled()
        #expect(!OnboardingGate.needsSetup(settings: settings, login: .enabled, scheduler: .enabled))
        #expect(OnboardingGate.needsSetup(settings: settings, login: .notRegistered, scheduler: .enabled))
        #expect(OnboardingGate.needsSetup(settings: settings, login: .requiresApproval, scheduler: .enabled))
        #expect(OnboardingGate.needsSetup(settings: settings, login: .enabled, scheduler: .requiresApproval))
        #expect(OnboardingGate.needsSetup(settings: settings, login: .enabled, scheduler: .notFound))
        settings.enabled = false
        #expect(OnboardingGate.needsSetup(settings: settings, login: .enabled, scheduler: .enabled))
        #expect(OnboardingGate.needsSetup(settings: nil, login: .enabled, scheduler: .enabled))
    }

    @Test @MainActor func openingOnboardingDoesNotEnableAnything() throws {
        let login = FakeScheduleService()
        let scheduler = FakeScheduleService()
        let model = OnboardingController(store: store, login: login, scheduler: scheduler)
        #expect(model.loaded)
        #expect(model.launchAtLogin && model.settings.enabled)
        #expect(login.registrations == 0 && scheduler.registrations == 0)
        #expect(try store.loadSettings().enabled == false)
    }

    @Test @MainActor func onboardingSavesBothSettings() async throws {
        let login = FakeScheduleService()
        let scheduler = FakeScheduleService()
        let model = OnboardingController(store: store, login: login, scheduler: scheduler)
        model.settings.frequency = .weekly
        model.settings.weekday = 3
        model.settings.retentionDays = 60
        #expect(await model.save())
        let settings = try store.loadSettings()
        #expect(settings.frequency == .weekly && settings.weekday == 3 && settings.retentionDays == 60)
        #expect(!OnboardingGate.needsSetup(settings: settings, login: login.status, scheduler: scheduler.status))
    }

    @Test @MainActor func deliberatelyDisablingStillRequiresOnboardingNextLaunch() async throws {
        let login = FakeScheduleService()
        let scheduler = FakeScheduleService()
        let model = OnboardingController(store: store, login: login, scheduler: scheduler)
        model.launchAtLogin = false
        model.settings.enabled = false
        #expect(await model.save())
        #expect(OnboardingGate.needsSetup(settings: try store.loadSettings(), login: login.status, scheduler: scheduler.status))
    }

    @Test @MainActor func onboardingFailureRemainsVisibleAndKeepsCleanupOff() async throws {
        let login = FakeScheduleService()
        let scheduler = FakeScheduleService()
        scheduler.failRegistration = true
        let model = OnboardingController(store: store, login: login, scheduler: scheduler)
        #expect(await model.save() == false)
        #expect(model.errorMessage != nil)
        #expect(try store.loadSettings().enabled == false)
        #expect(OnboardingGate.needsSetup(settings: try store.loadSettings(), login: login.status, scheduler: scheduler.status))
    }

    @Test @MainActor func onboardingWaitsForApproval() async {
        let login = FakeScheduleService()
        let scheduler = FakeScheduleService()
        scheduler.statusAfterRegistration = .requiresApproval
        let model = OnboardingController(store: store, login: login, scheduler: scheduler)
        #expect(await model.save() == false)
        #expect(model.awaitingApproval)
        #expect(!model.checkApproval())
        scheduler.status = .enabled
        #expect(model.checkApproval())
    }

    @Test @MainActor func onboardingDoesNotOverwriteUnreadableSettings() async throws {
        try store.prepare()
        let file = store.directory.appendingPathComponent("settings.json")
        let data = Data("corrupt".utf8)
        try data.write(to: file)
        let login = FakeScheduleService()
        let model = OnboardingController(store: store, login: login, scheduler: FakeScheduleService())
        #expect(!model.loaded)
        #expect(await model.save() == false)
        #expect(try Data(contentsOf: file) == data)
        #expect(login.registrations == 0)
    }

    @Test @MainActor func loginItemCanBeEnabledAndDisabledWithoutChangingCleanupSettings() async throws {
        let initial = enabled()
        try store.saveSettings(initial)
        let service = FakeScheduleService()
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        #expect(controller.enabled)
        #expect(service.registrations == 1)
        await controller.setEnabled(true)
        #expect(service.registrations == 1)
        await controller.setEnabled(false)
        #expect(!controller.enabled)
        #expect(service.unregistrations == 1)
        await controller.setEnabled(false)
        #expect(service.unregistrations == 1)
        #expect(try store.loadSettings() == initial)
    }

    @Test @MainActor func loginRegistrationFailureShowsErrorWithoutEnablingToggle() async {
        let service = FakeScheduleService()
        service.failRegistration = true
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        #expect(!controller.enabled)
        #expect(controller.errorMessage != nil)
        #expect(!controller.updating)
    }

    @Test @MainActor func loginUnregistrationFailureRetainsActualStatus() async {
        let service = FakeScheduleService()
        service.status = .enabled
        service.failUnregistration = true
        let controller = LoginItemController(service: service)
        await controller.setEnabled(false)
        #expect(controller.enabled)
        #expect(controller.errorMessage != nil)
    }

    @Test @MainActor func loginStatusRefreshReflectsSystemSettingsChanges() {
        let service = FakeScheduleService()
        let controller = LoginItemController(service: service)
        service.status = .enabled
        controller.refresh()
        #expect(controller.enabled)
        service.status = .notRegistered
        controller.refresh()
        #expect(!controller.enabled)
    }

    @Test @MainActor func pendingLoginApprovalIsPreservedAndCanBeCancelled() async {
        let service = FakeScheduleService()
        service.status = .requiresApproval
        let controller = LoginItemController(service: service)
        await controller.setEnabled(true)
        #expect(controller.status == .requiresApproval)
        #expect(service.registrations == 0)
        await controller.setEnabled(false)
        #expect(controller.status == .notRegistered)
    }
}

private final class ScheduleTestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
