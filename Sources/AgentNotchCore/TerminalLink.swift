import Foundation

/// Where an agent's terminal is, from the environment its Claude Code process inherited from the
/// shell: enough to bring that exact tab (Warp) or at least its terminal app to the front.
public struct TerminalLink: Equatable, Sendable {
    /// Warp's per-pane focus link, `warp://session/<pane id>`.
    public var focusURL: String?
    /// Warp's pane id, which also finds the tab (and your name for it) in Warp's state.
    public var warpPaneId: String?
    /// The terminal app (`__CFBundleIdentifier`, set by macOS for apps it launches).
    public var bundleId: String?
    /// `TERM_PROGRAM`, e.g. `WarpTerminal`, `iTerm.app`, `Apple_Terminal`.
    public var program: String?

    public init(focusURL: String? = nil, warpPaneId: String? = nil, bundleId: String? = nil, program: String? = nil) {
        self.focusURL = focusURL
        self.warpPaneId = warpPaneId
        self.bundleId = bundleId
        self.program = program
    }

    public init?(environment env: [String: String]) {
        let link = TerminalLink(focusURL: env["WARP_FOCUS_URL"], warpPaneId: env["WARP_TERMINAL_SESSION_UUID"],
                                bundleId: env["__CFBundleIdentifier"], program: env["TERM_PROGRAM"])
        guard link.focusURL != nil || link.bundleId != nil else { return nil }
        self = link
    }

    /// The app's name for buttons: "Warp", "iTerm", "Terminal", or nil if unknown.
    public var appName: String? {
        switch program {
        case "WarpTerminal": return "Warp"
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "ghostty": return "Ghostty"
        case "vscode": return "VS Code"
        default: return focusURL != nil ? "Warp" : nil
        }
    }
}

/// Reads the environment out of a `KERN_PROCARGS2` buffer: argc, the executable path, padding,
/// argv, then `KEY=value` strings.
public enum ProcessArguments {
    public static func environment(fromProcArgs data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return [:] }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4
        // Executable path, then NUL padding up to argv.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var strings: [String] = []
        var start = index
        while index < bytes.count {
            if bytes[index] == 0 {
                if index == start { break }   // an empty string ends the list
                strings.append(String(decoding: bytes[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }
}
