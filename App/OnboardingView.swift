import SwiftUI
import ServiceManagement
import Carbon

struct OnboardingView: View {
    private enum Step: Hashable { case schedule }
    @State private var path: [Step] = []
    @State private var controller = OnboardingController()
    let close: () -> Void
    private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private var isSchedule: Bool { !path.isEmpty }
    private var editingDisabled: Bool { !controller.loaded || controller.saving || controller.awaitingApproval }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                progress("01", "Startup", active: !isSchedule, complete: isSchedule)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                progress("02", "Cleanup", active: isSchedule, complete: false)
                Spacer()
            }.padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 20)
            NavigationStack(path: $path) {
                page(schedule: false)
                    .opacity(isSchedule ? 0 : 1)
                    .navigationDestination(for: Step.self) { _ in page(schedule: true).navigationBarBackButtonHidden() }
            }
            Divider().padding(.horizontal, 32)
            footer
                .transaction { $0.animation = nil }
        }
        .frame(width: 640, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.indigo).environment(\.locale, DisplayText.locale)
    }

    private func progress(_ number: String, _ title: String, active: Bool, complete: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(active || complete ? Color.indigo.opacity(0.12) : Color.primary.opacity(0.05))
                if complete { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                else { Text(number).font(.system(size: 10, weight: .bold, design: .rounded)) }
            }.frame(width: 26, height: 26)
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
        }.foregroundStyle(active || complete ? Color.indigo : Color.secondary)
    }

    private func page(schedule: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(schedule ? "Make room.\nOn your schedule." : "A cleaner workspace.\nWithout the upkeep.")
                        .font(.system(size: 32, weight: .bold, design: .rounded)).tracking(-0.7)
                    Text(schedule ? "Pick a quiet time and decide how long to keep unused build data." : "Let old build data take care of itself. Start by keeping DerivedData Cleaner close at hand.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
                }.fixedSize(horizontal: false, vertical: true)
                if schedule { scheduleCards } else { startupCards }
                if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if controller.awaitingApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One last step in System Settings.").font(.headline)
                        Text("Allow the app in Login Items, then check the status below.").font(.callout)
                        Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
                }
            }.padding(.horizontal, 36).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var startupCards: some View {
        VStack(spacing: 24) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { _ in Circle().fill(Color.primary.opacity(0.12)).frame(width: 7, height: 7) }
                    Spacer()
                    Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(.indigo)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }.padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                HStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.indigo)
                        .frame(width: 74, height: 74)
                        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quietly in the background.").font(.system(size: 16, weight: .semibold))
                        Text("Your schedule. Your retention rules.\nA little more room for what’s next.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    Spacer()
                }.padding(24)
            }
            .background(Color.indigo.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.indigo.opacity(0.12)))
            .accessibilityElement(children: .ignore).accessibilityLabel("DerivedData Cleaner runs quietly from your menu bar.")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    icon("power")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch at Login").font(.system(size: 15, weight: .semibold))
                        Text("Ready whenever you sign in to your Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Launch at Login", isOn: $controller.launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                Label("Lives in your menu bar. No extra window to manage.", systemImage: "menubar.rectangle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(20).background(cardBackground).disabled(editingDisabled)
        }
    }

    private var scheduleCards: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    icon("calendar")
                    Text("Automatic Cleanup").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Toggle("Enable Automatic Cleanup", isOn: $controller.settings.enabled).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                scheduleRow("Repeat") {
                    HStack(spacing: 2) {
                        ForEach(CleanupSettings.Frequency.allCases, id: \.self) { frequency in
                            Button { controller.settings.frequency = frequency } label: {
                                Text(frequency == .daily ? "Daily" : "Weekly")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 26)
                                    .background(controller.settings.frequency == frequency ? Color.indigo : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(controller.settings.frequency == frequency ? Color.white : Color.primary)
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(controller.settings.frequency == frequency ? [.isSelected] : [])
                        }
                    }.padding(3).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                scheduleRow("Day") {
                    if controller.settings.frequency == .weekly {
                        choiceMenu("Day", selection: $controller.settings.weekday, values: Array(1...7), labels: weekdays)
                    } else {
                        choiceMenu("Day", selection: .constant(0), values: [0], labels: ["Every day"]).disabled(true)
                    }
                }
                scheduleRow("Time") {
                    HStack(spacing: 8) {
                        choiceMenu("Hour", selection: $controller.settings.hour, values: Array(0...23),
                                   labels: (0...23).map { String(format: "%02d", $0) })
                        Text(":").foregroundStyle(.secondary)
                        choiceMenu("Minute", selection: $controller.settings.minute, values: Array(0...59),
                                   labels: (0...59).map { String(format: "%02d", $0) })
                    }.monospacedDigit()
                }
                Label("Local time. If your Mac is asleep, cleanup runs after waking.", systemImage: "moon")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20).background(cardBackground).disabled(editingDisabled)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    icon("archivebox")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep recent builds").font(.system(size: 15, weight: .semibold))
                        Text("Delete data unused for at least").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Retention days", value: $controller.settings.retentionDays, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 58).monospacedDigit()
                    Text("days").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remove data for missing projects").font(.system(size: 13, weight: .medium))
                        Text("Also clean up when the original project no longer exists.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Remove data for missing projects", isOn: $controller.settings.includeMissingWorkspaces)
                        .labelsHidden().toggleStyle(.switch)
                }
            }.padding(20).background(cardBackground).disabled(editingDisabled)
            Label("Matching build data is permanently deleted. Your project source files stay untouched.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func choiceMenu(_ title: String, selection: Binding<Int>, values: [Int], labels: [String]) -> some View {
        ScheduleChoice(title: title, selection: selection, values: values, labels: labels)
            .frame(height: 32)
    }

    private func scheduleRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            control().frame(width: 220).controlSize(.regular)
        }.frame(minHeight: 24)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium)).foregroundStyle(.indigo)
            .frame(width: 36, height: 36).background(Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
    }
    private var footer: some View {
        HStack(spacing: 16) {
            if isSchedule {
                Button { withAnimation { _ = path.removeLast() } } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain).disabled(controller.saving || controller.awaitingApproval)
            }
            Spacer()
            if !controller.loaded {
                Button("Retry", action: controller.reload).buttonStyle(.borderedProminent)
            } else if controller.awaitingApproval {
                Button("Check Status") { if controller.checkApproval() { close() } }.buttonStyle(.borderedProminent)
            } else if isSchedule {
                Button(controller.saving ? "Saving…" : "Finish") {
                    Task { if await controller.save() { close() } }
                }.buttonStyle(.borderedProminent).disabled(controller.saving).keyboardShortcut(.defaultAction)
            } else {
                Button { withAnimation { path.append(.schedule) } } label: { Label("Continue", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.controlSize(.large).padding(.horizontal, 36).padding(.vertical, 22)
    }
}
/// Native popup buttons use the entire proposed width, unlike Menu's intrinsic label layout.
private struct ScheduleChoice: NSViewRepresentable {
    let title: String
    @Binding var selection: Int
    let values: [Int]
    let labels: [String]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, values: values) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.values = values
        if button.itemTitles != labels {
            button.removeAllItems()
            button.addItems(withTitles: labels)
        }
        button.selectItem(at: values.firstIndex(of: selection) ?? 0)
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220, height: 32)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>
        var values: [Int]
        init(selection: Binding<Int>, values: [Int]) {
            self.selection = selection
            self.values = values
        }
        @objc func choose(_ sender: NSPopUpButton) {
            guard values.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = values[sender.indexOfSelectedItem]
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(showSetup),
                                              name: Self.showSetupNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showSettings),
                                              name: Self.showSettingsNotification, object: nil)
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        switch OnboardingGate.launchDestination(needsSetup: needsSetup, launchedAtLogin: loginLaunch) {
        case .setup: showSetup()
        case .settings: showSettings()
        case .menuBar: break
        }
    }

    static let showSetupNotification = Notification.Name("dev.kohey.DerivedDataCleaner.showSetup")
    static let showSettingsNotification = Notification.Name("dev.kohey.DerivedDataCleaner.showSettings")

    private var needsSetup: Bool {
        OnboardingGate.needsSetup(settings: try? ScheduleStore.standard.loadSettings(),
                                  login: LoginItemService().status, scheduler: LaunchAgentService().status)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if needsSetup { showSetup() } else { showSettings() }
        return false
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "DerivedData Cleaner Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppSettingsView().environment(\.locale, DisplayText.locale))
            window.center()
            settingsWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func showSetup() {
        if let setupWindow, setupWindow.isVisible {
            setupWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to DerivedData Cleaner"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView { [weak window] in window?.close() })
            window.center()
            setupWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
