import Foundation
import ServiceManagement

/// Your choices from the notch's settings menu, kept in UserDefaults.
struct Preferences: Codable, Equatable {
    enum DoneCards: String, Codable, CaseIterable {
        case every, long, off

        var label: String {
            switch self {
            case .every: return "Every finished reply"
            case .long: return "Replies over 30 seconds"
            case .off: return "Never"
            }
        }
    }

    /// Replies shorter than this don't pop a card under `.long`.
    static let longReply: TimeInterval = 30
    /// A request waiting this long gets a reminder, and again every time this much more passes.
    /// (`AGENTNOTCH_NUDGE_AFTER=<seconds>` shortens it for testing.)
    static let nudgeAfter: TimeInterval =
        ProcessInfo.processInfo.environment["AGENTNOTCH_NUDGE_AFTER"].flatMap(Double.init) ?? 3 * 60

    var chimes = true
    var doneCards = DoneCards.every
    var cardSeconds: Double = 8
    var nudges = true

    private static let key = "preferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return preferences
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// "Start at login", as a macOS login item for this app. It adds its hooks whenever it starts,
/// so after a reboot sessions report without running the Start script.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // macOS may want you to allow it in System Settings first.
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data("AgentNotch: login item: \(error)\n".utf8))
        }
    }
}
