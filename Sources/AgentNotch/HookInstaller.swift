import Foundation

/// Adds AgentNotch's hooks to `~/.claude/settings.json` while the app runs and removes them when
/// it quits, so Claude Code only reports to the notch while there's a notch to report to (and
/// shows no hook errors while the app is off). Claude Code picks the change up live.
///
/// Uses the jq scripts bundled in Resources (they keep the file's key order and formatting).
/// `AGENTNOTCH_MANAGE_HOOKS=0` turns this off.
enum HookInstaller {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AGENTNOTCH_MANAGE_HOOKS"] != "0"
    }

    static func install() { run("install-hooks.sh") }
    static func uninstall() { run("uninstall-hooks.sh") }

    private static func run(_ script: String) {
        guard enabled else { return }
        guard let url = Bundle.main.url(forResource: script, withExtension: nil) else {
            Log.debug("\(script) not bundled (running outside the .app?); hooks left as they are")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path, "--quiet"]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("AgentNotch: \(script) failed to start: \(error)\n".utf8))
            return
        }
        if process.terminationStatus != 0 {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            FileHandle.standardError.write(Data("AgentNotch: \(script) exited \(process.terminationStatus): \(message)\n".utf8))
        } else {
            Log.debug("\(script) done")
        }
    }
}
