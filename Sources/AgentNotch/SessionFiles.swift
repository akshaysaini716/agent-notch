import AgentNotchCore
import Darwin
import Foundation

/// Claude Code's own bookkeeping on disk: one `~/.claude/sessions/<pid>.json` per running
/// session, and transcripts under `~/.claude/projects/<folder>/<session id>.jsonl`.
enum SessionFiles {
    static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    /// Sessions whose process is still running. Files of crashed processes are skipped.
    static func open() -> [OpenSession] {
        let directory = claudeDirectory.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let session = OpenSession(data: data),
                  isRunning(session.pid) else { return nil }
            return session
        }
    }

    /// The session's transcript; its folder name is derived from the cwd, so look it up by id.
    static func transcript(for sessionId: String) -> String? {
        let projects = claudeDirectory.appendingPathComponent("projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let path = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionId).jsonl").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
