import SwiftUI

@main
struct DerivedDataCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var menuStatus = MenuStatusModel()
    var body: some Scene {
        MenuBarExtra("DerivedData Cleaner", image: "MenuBarIcon") {
            MenuContent(status: menuStatus)
                .environment(\.locale, DisplayText.locale)
        }
    }
}

private struct MenuContent: View {
    let status: MenuStatusModel
    var body: some View {
        if let error = status.error {
            Text(error)
        } else if let success = status.state.latestSuccess, let finished = success.finishedAt {
            Text("Last successful run: \(DisplayText.date(finished))")
            if let bytes = success.reclaimedBytes {
                Text("Space freed: ~\(DisplayText.bytes(bytes))")
            } else { Text("Space freed: Not measured") }
        } else {
            Text("Scheduled cleanup: No successful runs yet")
        }
        Divider()
        if status.needsSetup {
            Button("Setup…") { NotificationCenter.default.post(name: AppDelegate.showSetupNotification, object: nil) }
        }
        Button("Settings…") { NotificationCenter.default.post(name: AppDelegate.showSettingsNotification, object: nil) }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .onAppear { status.refresh() }
    }
}

@MainActor @Observable
private final class MenuStatusModel {
    var state = ScheduleState()
    var needsSetup = false
    var error: String?
    @ObservationIgnored private var observer: NSObjectProtocol?
    init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: ScheduleStore.stateChangedNotification, object: ScheduleStore.standard.directory.path, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        needsSetup = OnboardingGate.needsSetup(
            settings: try? ScheduleStore.standard.loadSettings(),
            login: LoginItemService().status, scheduler: LaunchAgentService().status
        )
        do {
            state = try ScheduleStore.standard.loadState()
            error = nil
        } catch { self.error = "Could not load scheduled cleanup results" }
    }
}
