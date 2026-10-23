import Foundation
import ServiceManagement
import Observation

@MainActor
struct LoginItemService: ScheduleService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

/// The OS is the source of truth; no second preference can drift out of sync.
@MainActor @Observable
final class LoginItemController {
    private let service: any ScheduleService
    private(set) var status: SMAppService.Status
    private(set) var updating = false
    private(set) var errorMessage: String?
    var enabled: Bool { status == .enabled || status == .requiresApproval }

    init(service: any ScheduleService = LoginItemService()) {
        self.service = service
        self.status = service.status
    }

    func refresh() { status = service.status }

    func setEnabled(_ enabled: Bool) async {
        guard !updating else { return }
        updating = true
        errorMessage = nil
        defer { refresh(); updating = false }
        do {
            refresh()
            if enabled {
                if status != .enabled && status != .requiresApproval { try service.register() }
                guard service.status == .enabled || service.status == .requiresApproval else {
                    throw LoginError.registrationUnavailable
                }
            } else if status == .enabled || status == .requiresApproval {
                try await service.unregister()
            }
        } catch { errorMessage = DisplayText.error(error) }
    }

    enum LoginError: EnglishDescribedError {
        case registrationUnavailable
        var englishDescription: String { "Launch at login could not be enabled. Check Login Items in System Settings." }
    }
}

@MainActor
protocol ScheduleService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
struct LaunchAgentService: ScheduleService {
    static let plistName = "dev.kohey.DerivedDataCleaner.scheduler.plist"
    private var service: SMAppService { .agent(plistName: Self.plistName) }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

@MainActor
struct ScheduleController {
    let store: ScheduleStore
    let service: any ScheduleService

    func save(_ requested: CleanupSettings, now: Date = .now) async throws {
        var settings = requested
        settings.revision = UUID()
        settings.effectiveFrom = now
        try settings.validate()
        // Fail closed: neither a registration failure nor an old helper may
        // execute the new schedule until settings have been committed.
        var disabled = settings
        disabled.enabled = false
        try store.withLock { try store.saveSettings(disabled) }
        if settings.enabled {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            guard service.status == .enabled || service.status == .requiresApproval else {
                throw ServiceError.registrationUnavailable
            }
            try store.withLock { try store.saveSettings(settings) }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
        }
    }

    enum ServiceError: EnglishDescribedError {
        case registrationUnavailable
        var englishDescription: String {
            "Background execution could not be registered. Check Login Items in System Settings."
        }
    }
}
