import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct TerminalLinkTests {
    /// Builds a KERN_PROCARGS2-style buffer: argc, exec path, padding, argv, env.
    private func procArgs(argv: [String], env: [String]) -> Data {
        var bytes: [UInt8] = []
        var argc = UInt32(argv.count).littleEndian
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        bytes += Array("/usr/local/bin/claude".utf8) + [0, 0, 0, 0]
        for string in argv + env { bytes += Array(string.utf8) + [0] }
        bytes += [0, 0]
        return Data(bytes)
    }

    @Test func readsEnvironmentAfterArguments() {
        let env = ProcessArguments.environment(fromProcArgs: procArgs(
            argv: ["claude", "--model", "opus"],
            env: ["TERM_PROGRAM=WarpTerminal", "WARP_FOCUS_URL=warp://session/ef59", "EMPTY=", "A=b=c"]))
        #expect(env["TERM_PROGRAM"] == "WarpTerminal")
        #expect(env["WARP_FOCUS_URL"] == "warp://session/ef59")
        #expect(env["EMPTY"] == "")
        #expect(env["A"] == "b=c")
        #expect(env["claude"] == nil && env["--model"] == nil)
        #expect(ProcessArguments.environment(fromProcArgs: Data([1, 0])) == [:])
    }

    @Test func warpSessionsLinkToTheirPane() throws {
        let link = try #require(TerminalLink(environment: [
            "WARP_FOCUS_URL": "warp://session/ef597bdd", "WARP_TERMINAL_SESSION_UUID": "ef597bdd",
            "__CFBundleIdentifier": "dev.warp.Warp-Stable", "TERM_PROGRAM": "WarpTerminal",
        ]))
        #expect(link.focusURL == "warp://session/ef597bdd")
        #expect(link.warpPaneId == "ef597bdd")
        #expect(link.appName == "Warp")
    }

    @Test func otherTerminalsFallBackToTheirApp() throws {
        let link = try #require(TerminalLink(environment: ["__CFBundleIdentifier": "com.googlecode.iterm2", "TERM_PROGRAM": "iTerm.app"]))
        #expect(link.focusURL == nil)
        #expect(link.appName == "iTerm")
        #expect(TerminalLink(environment: ["HOME": "/x"]) == nil)
    }

    @Test func tabNameIsTheAgentsName() {
        var board = Board()
        board.sync(open: [OpenSession(pid: 9427, sessionId: "s", cwd: "/w/payments-api", busy: true,
                                      startedAt: Date(), statusSince: Date())], at: Date())
        board.setTitle("Notch agent monitor", for: "s")
        #expect(board.sessions["s"]?.displayName == "Notch agent monitor")
        board.setTabName("release prep", for: "s")
        #expect(board.sessions["s"]?.displayName == "release prep")
        board.setTabName("  ", for: "s")   // an unnamed tab falls back to the title
        #expect(board.sessions["s"]?.displayName == "Notch agent monitor")
    }
}
