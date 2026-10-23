import AppKit
import Foundation
import OSLog

@main
struct SchedulerMain {
    @MainActor static func main() {
        // Explicit paths are required for the diagnostic one-shot mode.
        let args = CommandLine.arguments
        if args.count > 1 {
            guard args.count == 4, ["--run-once", "--serve"].contains(args[1]) else { exit(64) }
            let store = ScheduleStore(directory: URL(fileURLWithPath: args[2]))
            let root = URL(fileURLWithPath: args[3])
            if args[1] == "--serve" {
                let scheduler = SchedulerLoop(store: store, root: root)
                scheduler.start()
                withExtendedLifetime(scheduler) { RunLoop.main.run() }
                return
            }
            do {
                try ScheduledCleanupRunner(store: store, root: root).runIfDue()
                return
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        let scheduler = SchedulerLoop()
        scheduler.start()
        withExtendedLifetime(scheduler) { RunLoop.main.run() }
    }
}

@MainActor
private final class SchedulerLoop {
    private let store: ScheduleStore
    private let root: URL
    private var timer: Timer?
    private var watcher: (any DispatchSourceFileSystemObject)?
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "dev.kohey.DerivedDataCleaner", category: "scheduler")

    init(store: ScheduleStore = .standard, root: URL = DerivedDataScanner.defaultRoot) {
        self.store = store
        self.root = root
    }

    func start() {
        do {
            try store.prepare()
            let fd = open(store.directory.path, O_EVTONLY)
            guard fd >= 0 else { throw ScheduleError.lockUnavailable }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.refresh() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        } catch {
            logger.error("Cannot watch settings: \(DisplayText.error(error), privacy: .private)")
            // Restart through launchd instead of silently missing configuration changes.
            exit(1)
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }

    private func refresh() {
        timer?.invalidate()
        do {
            try ScheduledCleanupRunner(store: store, root: root).runIfDue()
            let settings = try store.loadSettings()
            guard let next = try store.loadState().nextDate(for: settings) else { return }
            arm(after: max(1, next.timeIntervalSinceNow))
        } catch ScheduleError.lockUnavailable {
            // A settings write or manual cleanup may briefly hold the lock.
            arm(after: 1)
        } catch {
            logger.error("Scheduled cleanup failed: \(DisplayText.error(error), privacy: .private)")
            arm(after: 60)
        }
    }

    private func arm(after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
