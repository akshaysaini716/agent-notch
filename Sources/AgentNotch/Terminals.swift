import AgentNotchCore
import AppKit
import Darwin
import SQLite3

enum Terminals {
    /// The terminal a Claude Code process runs in, from the environment it inherited.
    static func link(forPid pid: Int32) -> TerminalLink? {
        guard let args = procArgs(pid) else { return nil }
        return TerminalLink(environment: ProcessArguments.environment(fromProcArgs: args))
    }

    /// Brings the agent's terminal to the front: its exact Warp tab, or else its terminal app.
    @MainActor
    static func open(_ link: TerminalLink) {
        if let focus = link.focusURL, let url = URL(string: focus) {
            NSWorkspace.shared.open(url)
        } else if let bundleId = link.bundleId,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
        }
    }

    /// Argv and environment of a process (same user only), via `KERN_PROCARGS2`.
    private static func procArgs(_ pid: Int32) -> Data? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Data(buffer.prefix(size))
    }
}

/// Your names for Warp tabs, from Warp's own state database (read-only). A Claude Code process
/// knows its Warp pane id (`WARP_TERMINAL_SESSION_UUID`); the pane belongs to a tab, and the tab
/// may have a name you gave it.
enum WarpTabs {
    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")

    /// Pane id → tab name, for the panes that are in a named tab.
    static func names(forPanes panes: [String]) -> [String: String] {
        guard !panes.isEmpty, FileManager.default.fileExists(atPath: database.path) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let sql = """
            SELECT lower(hex(tp.uuid)), t.custom_title FROM terminal_panes tp
            JOIN pane_nodes pn ON pn.id = tp.id
            JOIN tabs t ON t.id = pn.tab_id
            WHERE t.custom_title IS NOT NULL AND t.custom_title != ''
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        let wanted = Set(panes.map { $0.lowercased() })
        var names: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pane = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: pane)
            if wanted.contains(id) { names[id] = String(cString: title) }
        }
        return names
    }
}
