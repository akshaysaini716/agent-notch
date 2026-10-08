import Darwin
import Foundation

/// Finds running Claude Code processes and their working directories, so sessions whose
/// process is gone (killed without a SessionEnd hook) can be cleared from the notch.
enum ClaudeProcesses {
    static let names: Set<String> = ["claude"]

    /// Working directories of every running `claude` process.
    static func workingDirectories() -> Set<String> {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        var directories = Set<String>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard names.contains(name(of: pid)), let directory = workingDirectory(of: pid) else { continue }
            directories.insert(directory)
        }
        return directories
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
