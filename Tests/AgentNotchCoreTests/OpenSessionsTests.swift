import Foundation
import Testing
@testable import AgentNotchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct OpenSessionTests {
    /// Shape of `~/.claude/sessions/<pid>.json` as written by Claude Code 2.1.293.
    @Test func parsesClaudeCodeSessionFile() throws {
        let json = """
        {"pid":49033,"sessionId":"efef458d","cwd":"/w/payments-api","startedAt":1791435494217,
         "version":"2.1.293","kind":"interactive","name":"payments-api-f0","nameSource":"derived",
         "status":"idle","updatedAt":1791438941527,"statusUpdatedAt":1791438941527}
        """
        let session = try #require(OpenSession(data: Data(json.utf8)))
        #expect(session.pid == 49033)
        #expect(session.sessionId == "efef458d")
        #expect(session.cwd == "/w/payments-api")
        #expect(!session.busy)
        #expect(!session.nameIsCustom)
        #expect(session.startedAt == Date(timeIntervalSince1970: 1_791_435_494.217))
        #expect(session.statusSince == Date(timeIntervalSince1970: 1_791_438_941.527))
    }

    @Test func busyAndCustomNames() throws {
        let json = #"{"pid":1,"sessionId":"s","status":"busy","name":"release prep","nameSource":"user","startedAt":1}"#
        let session = try #require(OpenSession(data: Data(json.utf8)))
        #expect(session.busy)
        #expect(session.nameIsCustom)
        #expect(OpenSession(data: Data(#"{"sessionId":"no pid"}"#.utf8)) == nil)
    }
}

@Suite struct TranscriptDigestTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func readsPromptStepsAndLastReply() {
        let lines = [
            line(["type": "user", "message": ["role": "user", "content": "old prompt"]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "x", "name": "Read", "input": ["file_path": "/a"]]]]]),
            line(["type": "user", "message": ["role": "user", "content": "why is the spark job failing"]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t1", "name": "Bash",
                                                                "input": ["command": "kubectl get pods"]]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": false]]],
                  "toolUseResult": ["stdout": "driver-0  OOMKilled", "stderr": "", "interrupted": false]]),
            line(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent noise"]]]]),
            line(["type": "user", "isMeta": true, "message": ["content": "injected reminder"]]),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "  The driver is OOMKilled.  "]]]]),
            line(["type": "last-prompt", "lastPrompt": "<command-name>/clear</command-name>"]),
        ].joined(separator: "\n")
        let digest = TranscriptDigest.parse(Data(lines.utf8))
        #expect(digest.prompt == "why is the spark job failing")
        #expect(digest.steps.map(\.tool) == ["Bash"])
        #expect(digest.steps.first?.state == .done)
        #expect(digest.live == .command("kubectl get pods", output: ["driver-0  OOMKilled"], finished: .succeeded))
        #expect(digest.lastReply == "The driver is OOMKilled.")
    }

    @Test func readsOnlyTheTailOfBigTranscripts() throws {
        var lines = (0..<2000).map { line(["type": "assistant", "n": $0, "message": ["content": [["type": "text", "text": String(repeating: "x", count: 200)]]]]) }
        lines.append(line(["type": "user", "message": ["content": "latest prompt"]]))
        lines.append(line(["type": "assistant", "message": ["content": [["type": "text", "text": "latest reply"]]]]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let digest = try #require(TranscriptDigest.read(path: url.path, tailBytes: 4096))
        #expect(digest.prompt == "latest prompt")
        #expect(digest.lastReply == "latest reply")
    }
}

@Suite struct BoardSyncTests {
    private func open(_ id: String, pid: Int32, busy: Bool, started: TimeInterval = 0, since: TimeInterval = 0) -> OpenSession {
        OpenSession(pid: pid, sessionId: id, cwd: "/w/payments-api", busy: busy,
                    startedAt: t0.addingTimeInterval(started), statusSince: t0.addingTimeInterval(since))
    }

    @Test func listsEveryOpenSessionNewestFirst() {
        var board = Board()
        let found = board.sync(open: [open("old", pid: 1, busy: false, started: 0, since: 50),
                                      open("new", pid: 2, busy: true, started: 100, since: 120)], at: t0.addingTimeInterval(200))
        #expect(Set(found) == ["old", "new"])
        #expect(board.orderedSessions.map(\.id) == ["new", "old"])
        #expect(board.sessions["old"]?.status == .ready)
        #expect(board.sessions["old"]?.idleSince == t0.addingTimeInterval(50))
        #expect(board.sessions["new"]?.status == .working)
        #expect(board.sessions["new"]?.turnStartedAt == t0.addingTimeInterval(120))
        // Already known: not "discovered" again.
        #expect(board.sync(open: [open("old", pid: 1, busy: false), open("new", pid: 2, busy: true)], at: t0).isEmpty)
    }

    @Test func closedSessionsDisappear() {
        var board = Board()
        board.sync(open: [open("a", pid: 1, busy: false), open("b", pid: 2, busy: false)], at: t0)
        board.sync(open: [open("a", pid: 1, busy: false)], at: t0)
        #expect(Array(board.sessions.keys) == ["a"])
    }

    @Test func hookStatusWinsOverTheSessionFile() throws {
        var board = Board()
        board.sync(open: [open("s1", pid: 1, busy: false)], at: t0)
        board.apply(try HookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/w/payments-api"]), at: t0)
        board.sync(open: [open("s1", pid: 1, busy: false)], at: t0)
        #expect(board.sessions["s1"]?.status == .working)
        #expect(board.sessions["s1"]?.pid == 1)
    }

    @Test func digestFillsInQuietSessionsWithoutOverridingHooks() throws {
        var board = Board()
        board.sync(open: [open("s1", pid: 1, busy: false)], at: t0)
        let interrupted = StepRecord(id: "t", tool: "Bash", step: Step(symbol: "terminal", text: "Running ls"), state: .running)
        board.apply(TranscriptDigest(prompt: "fix it", steps: [interrupted], lastReply: "Done."), to: "s1")
        let session = try #require(board.sessions["s1"])
        #expect(session.prompt == "fix it")
        #expect(session.lastReply == "Done.")
        #expect(session.history.map(\.state) == [.done])   // idle: nothing is still running
    }

    @Test func pidSessionsAreLeftToTheSessionFiles() {
        var board = Board()
        board.sync(open: [open("s1", pid: 1, busy: false)], at: t0)
        #expect(board.reap(at: t0.addingTimeInterval(9999), grace: 90) { _ in false }.isEmpty)
        board.prune(at: t0.addingTimeInterval(Board.staleAfter * 10))
        #expect(board.sessions["s1"] != nil)
    }

    @Test func customNameBeatsTitle() {
        var board = Board()
        board.sync(open: [OpenSession(pid: 1, sessionId: "s", cwd: "/w/p", name: "release prep", nameIsCustom: true,
                                      busy: false, startedAt: t0, statusSince: t0)], at: t0)
        board.setTitle("Some title", for: "s")
        #expect(board.sessions["s"]?.displayName == "release prep")
    }
}
