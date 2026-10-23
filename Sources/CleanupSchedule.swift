import Foundation
import Darwin

struct CleanupSettings: Codable, Equatable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Sendable { case daily, weekly }
    var enabled = false
    var frequency: Frequency = .daily
    /// Calendar weekday: Sunday = 1, Saturday = 7.
    var weekday = 1
    var hour = 2
    var minute = 0
    var retentionDays = 30
    var includeMissingWorkspaces = true
    var revision = UUID()
    var effectiveFrom = Date.now

    func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute), (1...7).contains(weekday),
              (1...3650).contains(retentionDays), effectiveFrom.timeIntervalSince1970.isFinite else {
            throw ScheduleError.invalidSettings
        }
    }

    var policy: ScanPolicy {
        ScanPolicy(retentionDays: retentionDays, includeMissingWorkspaces: includeMissingWorkspaces)
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, (try? validate()) != nil else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if frequency == .weekly { components.weekday = weekday }
        // Missing DST times run at the next valid time; repeated times run once.
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
}

enum ScheduleError: EnglishDescribedError {
    case invalidSettings, lockUnavailable, unsafeStorage
    var englishDescription: String {
        switch self {
        case .unsafeStorage: "The settings folder or file is not a safe, user-owned location."
        case .invalidSettings: "Check the schedule and enter a retention period between 1 and 3650 days."
        case .lockUnavailable: "Another cleanup or settings update may be running. Wait for it to finish and try again."
        }
    }
}

struct ScheduledRun: Codable, Equatable, Sendable {
    var startedAt: Date
    var finishedAt: Date?
    var deleted = 0
    var skipped = 0
    var failed = 0
    var messages: [String] = []
    /// Nil for older history or incomplete size measurement.
    var reclaimedBytes: Int64?
    var succeeded: Bool { finishedAt != nil && failed == 0 }
}

struct ScheduleState: Codable, Equatable, Sendable {
    var revision: UUID?
    var lastAttempt: Date?
    var lastRun: ScheduledRun?
    var lastSuccessfulRun: ScheduledRun?

    var latestSuccess: ScheduledRun? {
        lastSuccessfulRun ?? (lastRun?.succeeded == true ? lastRun : nil)
    }

    func nextDate(for settings: CleanupSettings, calendar: Calendar = .current) -> Date? {
        let baseline = revision == settings.revision ? max(lastAttempt ?? settings.effectiveFrom, settings.effectiveFrom) : settings.effectiveFrom
        return settings.nextDate(after: baseline, calendar: calendar)
    }
}

struct ScheduleStore: Sendable {
    static let stateChangedNotification = Notification.Name("dev.kohey.DerivedDataCleaner.stateChanged")
    let directory: URL
    static var standard: ScheduleStore {
        ScheduleStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DerivedDataCleaner", isDirectory: true))
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScheduleError.unsafeStorage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
            throw ScheduleError.unsafeStorage
        }
    }

    func loadSettings() throws -> CleanupSettings {
        let settings: CleanupSettings = try read("settings.json") ?? CleanupSettings()
        try settings.validate()
        return settings
    }

    func loadState() throws -> ScheduleState { try read("state.json") ?? ScheduleState() }
    func saveSettings(_ settings: CleanupSettings) throws {
        try settings.validate()
        try write(settings, name: "settings.json")
    }
    func saveState(_ state: ScheduleState) throws {
        try write(state, name: "state.json")
    }
    func notifyStateChanged() {
        DistributedNotificationCenter.default().postNotificationName(Self.stateChangedNotification,
            object: directory.path, userInfo: nil, deliverImmediately: true)
    }

    /// Shared by settings updates and helper runs, including separate processes.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let descriptor = open(directory.appendingPathComponent("schedule.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScheduleError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ScheduleError.lockUnavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func read<T: Decodable>(_ name: String) throws -> T? {
        try prepare()
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ScheduleError.unsafeStorage
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        let limit = 4 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= limit,
              fchmod(fd, 0o600) == 0 else { throw ScheduleError.unsafeStorage }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ScheduleError.unsafeStorage }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        try prepare()
        // The enclosing directory is private before any bytes are written.
        let destination = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

}

struct ScheduledCleanupRunner: Sendable {
    let store: ScheduleStore
    let root: URL
    var scanner = DerivedDataScanner()
    var deleter = DerivedDataDeleter()

    /// Called at startup, at the timer deadline, and on wake/config/clock changes.
    /// Claims the occurrence before deleting, preventing replay after crashes.
    @discardableResult
    func runIfDue(now: Date = .now, calendar: Calendar = .current) throws -> ScheduledRun? {
        let completed: ScheduledRun? = try store.withLock {
            let settings = try store.loadSettings()
            var state = try store.loadState()
            guard let next = state.nextDate(for: settings, calendar: calendar), next <= now else { return nil }
            state.lastSuccessfulRun = state.latestSuccess
            state.revision = settings.revision
            state.lastAttempt = now
            state.lastRun = ScheduledRun(startedAt: now)
            try store.saveState(state)
            var run = ScheduledRun(startedAt: now)
            run.reclaimedBytes = 0
            do {
                let report = try scanner.scan(root: root, policy: settings.policy, now: now)
                for result in deleter.delete(report.candidates, root: root, policy: settings.policy, now: now) {
                    switch result.outcome {
                    case .deleted:
                        run.deleted += 1
                        if let total = run.reclaimedBytes, let bytes = result.reclaimedBytes {
                            run.reclaimedBytes = total + bytes
                        } else { run.reclaimedBytes = nil }
                    case .skipped(let message):
                        run.skipped += 1
                        if run.messages.count < 100 { run.messages.append("\(result.directory.lastPathComponent): \(message)") }
                    case .failed(let message):
                        run.failed += 1
                        if run.messages.count < 100 { run.messages.append("\(result.directory.lastPathComponent): \(message)") }
                    }
                }
            } catch {
                run.failed += 1
                run.messages.append(DisplayText.error(error))
            }
            run.finishedAt = .now
            state.lastRun = run
            if run.succeeded { state.lastSuccessfulRun = run }
            try store.saveState(state)
            return run
        }
        // IPC must happen after releasing the settings/run lock.
        if completed != nil { store.notifyStateChanged() }
        return completed
    }
}
