import SwiftUI
import ServiceManagement

struct AppSettingsView: View {
    var body: some View {
        TabView {
            LoginSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
        }
    }
}

private struct LoginSettingsView: View {
    @State private var controller = LoginItemController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { controller.enabled },
                    set: { value in Task { await controller.setEnabled(value) } }
                ))
                .disabled(controller.updating)
            } header: {
                Text("Startup")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep DerivedData Cleaner in the menu bar when you log in. Automatic cleanup is configured separately in Schedule.")
                if controller.status == .requiresApproval {
                    Text("Approval required. Allow this app in Login Items in System Settings.")
                }
                if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
                if controller.status == .requiresApproval || controller.errorMessage != nil {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                }
                }
            }
        }
        .formStyle(.grouped).padding().frame(width: 540, height: 650)
        .task { controller.refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { controller.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refresh() }
    }
}

struct ScheduleSettingsView: View {
    @State private var settings = CleanupSettings()
    @State private var saved = CleanupSettings()
    @State private var state = ScheduleState()
    @State private var status = SMAppService.Status.notRegistered
    @State private var message: String?
    @State private var saving = false
    @State private var loaded = false
    @Environment(\.scenePhase) private var scenePhase
    private let store = ScheduleStore.standard
    private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        Form {
            Section {
                Toggle("Enable Automatic Cleanup", isOn: autoSaveBinding(\.enabled))
                Picker("Frequency", selection: autoSaveBinding(\.frequency)) {
                    Text("Daily").tag(CleanupSettings.Frequency.daily)
                    Text("Weekly").tag(CleanupSettings.Frequency.weekly)
                }
                if settings.frequency == .weekly {
                    Picker("Day", selection: autoSaveBinding(\.weekday)) {
                        ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) }
                    }
                }
                HStack {
                    Picker("Time", selection: autoSaveBinding(\.hour)) {
                        ForEach(0...23, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    Picker("Minute", selection: autoSaveBinding(\.minute)) {
                        ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden()
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Uses your Mac’s local time. Missed runs are combined into one cleanup after waking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper("Unused for at least \(settings.retentionDays) days", value: autoSaveBinding(\.retentionDays), in: 1...3650)
                Toggle("Also delete data for missing projects", isOn: autoSaveBinding(\.includeMissingWorkspaces))
            } header: {
                Text("Cleanup Rules")
            } footer: {
                Text("When enabled, matching DerivedData is permanently deleted without confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if saved.enabled, status == .enabled, let next = state.nextDate(for: saved) {
                    LabeledContent("Next Run", value: next <= .now ? "Pending" : DisplayText.date(next))
                }
                if let run = state.lastRun {
                    LabeledContent("Last Run", value: DisplayText.date(run.startedAt))
                    if run.finishedAt != nil {
                        LabeledContent("Results", value: "\(run.deleted) deleted · \(run.skipped) skipped · \(run.failed) failed")
                        if let bytes = run.reclaimedBytes {
                            LabeledContent("Space Freed", value: "~\(DisplayText.bytes(bytes))")
                        } else { LabeledContent("Space Freed", value: "Not measured") }
                        if !run.messages.isEmpty {
                            DisclosureGroup("Run Details") {
                                ScrollView { Text(run.messages.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                            }
                        }
                    } else { Text("Running, or the previous run was interrupted") }
                }
            } header: {
                Text("Activity")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if state.lastRun == nil { Text("No cleanups have run yet.") }
                    if let statusNotice { Text(statusNotice) }
                    if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    if saving { Text("Saving…") }
                    HStack(spacing: 16) {
                        Button("Refresh") { refreshStatus() }
                        if statusNotice != nil {
                            Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped).padding().frame(width: 540, height: 650)
        .disabled(saving || !loaded)
        .task { load() }
        .onChange(of: scenePhase) { if scenePhase == .active { refreshStatus() } }
    }

    private var statusNotice: String? {
        guard saved.enabled else { return nil }
        switch status {
        case .enabled: return nil
        case .requiresApproval: return "Allow background execution in System Settings"
        case .notRegistered: return "Not registered. Turn automatic cleanup off and on to register again."
        case .notFound: return "The background helper could not be found"
        @unknown default: return "Registration status is unavailable"
        }
    }

    private func load() {
        do {
            settings = try store.loadSettings()
            saved = settings
            loaded = true
            refreshStatus()
        } catch { message = "Could not load settings: \(DisplayText.error(error))" }
    }

    private func refreshStatus() {
        status = LaunchAgentService().status
        do { state = try store.loadState() }
        catch { message = "Could not load run results: \(DisplayText.error(error))" }
    }

    // Save only user edits. Loading persisted state must never trigger another save.
    private func autoSaveBinding<Value: Equatable>(_ keyPath: WritableKeyPath<CleanupSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                guard loaded, !saving, settings[keyPath: keyPath] != value else { return }
                settings[keyPath: keyPath] = value
                save()
            }
        )
    }

    private func save() {
        let requested = settings
        message = nil
        saving = true
        Task {
            do {
                try await ScheduleController(store: store, service: LaunchAgentService()).save(requested)
                load()
            } catch {
                // Reload persisted state: failed registration leaves automation off.
                load()
                message = "Could not save settings: \(DisplayText.error(error))"
            }
            refreshStatus()
            saving = false
        }
    }
}
