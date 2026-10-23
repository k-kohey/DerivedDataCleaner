import Foundation
import Observation
import ServiceManagement

enum OnboardingGate {
    enum LaunchDestination: Equatable { case setup, settings, menuBar }
    static func launchDestination(needsSetup: Bool, launchedAtLogin: Bool) -> LaunchDestination {
        if needsSetup { return .setup }
        return launchedAtLogin ? .menuBar : .settings
    }
    static func needsSetup(settings: CleanupSettings?, login: SMAppService.Status,
                           scheduler: SMAppService.Status) -> Bool {
        login != .enabled || settings?.enabled != true || scheduler != .enabled
    }
}

@MainActor @Observable
final class OnboardingController {
    var launchAtLogin = true
    var settings = CleanupSettings()
    private(set) var loaded = false
    private(set) var saving = false
    private(set) var errorMessage: String?
    private(set) var awaitingApproval = false
    private let store: ScheduleStore
    private let login: any ScheduleService
    private let scheduler: any ScheduleService

    init(store: ScheduleStore = .standard, login: any ScheduleService = LoginItemService(),
         scheduler: any ScheduleService = LaunchAgentService()) {
        self.store = store
        self.login = login
        self.scheduler = scheduler
        reload()
    }

    func reload() {
        do {
            settings = try store.loadSettings()
            // These are proposals only; nothing is enabled until Finish.
            settings.enabled = true
            launchAtLogin = true
            loaded = true
            errorMessage = nil
        } catch {
            loaded = false
            errorMessage = DisplayText.error(error)
        }
    }

    func save() async -> Bool {
        guard loaded, !saving else { return false }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try settings.validate()
            if launchAtLogin {
                if login.status != .enabled && login.status != .requiresApproval { try login.register() }
                guard login.status == .enabled || login.status == .requiresApproval else {
                    throw LoginItemController.LoginError.registrationUnavailable
                }
            } else if login.status == .enabled || login.status == .requiresApproval {
                try await login.unregister()
            }
            try await ScheduleController(store: store, service: scheduler).save(settings)
            awaitingApproval = (launchAtLogin && login.status == .requiresApproval)
                || (settings.enabled && scheduler.status == .requiresApproval)
            return !awaitingApproval
        } catch {
            errorMessage = "Setup could not be completed. Some settings may already have been applied. \(DisplayText.error(error))"
            return false
        }
    }

    func checkApproval() -> Bool {
        let ready = (!launchAtLogin || login.status == .enabled)
            && (!settings.enabled || scheduler.status == .enabled)
        awaitingApproval = !ready
        return ready
    }
}
