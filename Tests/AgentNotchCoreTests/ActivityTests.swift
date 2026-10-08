import Foundation
import Testing
@testable import AgentNotchCore

private func event(_ name: String, _ session: String = "s1", _ extra: [String: Any] = [:]) throws -> HookEvent {
    try HookEvent(["hook_event_name": name, "session_id": session, "cwd": "/work/agent-notch"].merging(extra) { $1 })
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct ActivityTests {
    @Test func historyPairsCallsByToolUseId() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Read", "tool_use_id": "r1", "tool_input": ["file_path": "/a.swift"]]), at: t0)
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Read", "tool_use_id": "r2", "tool_input": ["file_path": "/b.swift"]]), at: t0)
        board.apply(try event("PostToolUse", "s1", ["tool_name": "Read", "tool_use_id": "r2"]), at: t0)
        let history = try #require(board.sessions["s1"]?.history)
        #expect(history.map(\.state) == [.running, .done])
        board.apply(try event("PostToolUseFailure", "s1", ["tool_name": "Read", "tool_use_id": "r1"]), at: t0)
        #expect(board.sessions["s1"]?.history.map(\.state) == [.failed, .done])
    }

    @Test func historyKeepsOnlyTheLatestCalls() throws {
        var board = Board()
        for index in 0..<8 {
            board.apply(try event("PreToolUse", "s1", ["tool_name": "Grep", "tool_use_id": "g\(index)",
                                                       "tool_input": ["pattern": "p\(index)"]]), at: t0)
        }
        let history = try #require(board.sessions["s1"]?.history)
        #expect(history.count == AgentSession.historyLimit)
        #expect(history.last?.step.text == "Searching for “p7”")
    }

    @Test func stopLeavesNothingSpinning() throws {
        var board = Board()
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "sleep 100"]]), at: t0)
        board.apply(try event("Stop"), at: t0)
        #expect(board.sessions["s1"]?.history.map(\.state) == [.done])
    }

    @Test func bashPreviewGetsItsOutput() throws {
        var board = Board()
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "npm test"]]), at: t0)
        #expect(board.sessions["s1"]?.live == .command("npm test", output: [], finished: nil))
        board.apply(try event("PostToolUse", "s1", ["tool_name": "Bash", "tool_use_id": "b1", "tool_response": [
            "stdout": "\u{1B}[32mPASS\u{1B}[0m tests/a.test.ts\n\nTests: 48 passed", "stderr": "", "interrupted": false,
        ]]), at: t0)
        #expect(board.sessions["s1"]?.live == .command("npm test", output: ["PASS tests/a.test.ts", "Tests: 48 passed"],
                                                       finished: .succeeded))
    }

    @Test func failedBashIsMarkedFailed() throws {
        var board = Board()
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "false"]]), at: t0)
        board.apply(try event("PostToolUseFailure", "s1", ["tool_name": "Bash", "tool_use_id": "b1"]), at: t0)
        guard case .command(_, _, let finished) = try #require(board.sessions["s1"]?.live) else {
            Issue.record("expected a command preview")
            return
        }
        #expect(finished == .failed)
    }

    @Test func editPreviewShowsTheDiff() throws {
        var board = Board()
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Edit", "tool_use_id": "e1", "tool_input": [
            "file_path": "/x/Theme.swift", "old_string": "let a = 1", "new_string": "let a = 2",
        ]]), at: t0)
        #expect(board.sessions["s1"]?.live == .diff(file: "Theme.swift", lines: [
            .init(kind: .removed, text: "let a = 1"), .init(kind: .added, text: "let a = 2"),
        ], hidden: 0, added: 1, removed: 1))
    }

    @Test func taskToolsKeepThePreviousPreview() throws {
        var board = Board()
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "ls"]]), at: t0)
        board.apply(try event("PreToolUse", "s1", ["tool_name": "TodoWrite", "tool_use_id": "t1", "tool_input": ["todos": [
            ["content": "a", "status": "completed", "activeForm": "A"],
            ["content": "b", "status": "in_progress", "activeForm": "B"],
            ["content": "c", "status": "pending", "activeForm": "C"],
        ]]]), at: t0)
        let session = try #require(board.sessions["s1"])
        #expect(session.tasks == TaskProgress(done: 1, total: 3))
        #expect(session.live == .command("ls", output: [], finished: nil))
    }

    @Test func newPromptClearsTheActivity() throws {
        var board = Board()
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "ls"]]), at: t0)
        board.apply(try event("UserPromptSubmit"), at: t0)
        let session = try #require(board.sessions["s1"])
        #expect(session.history.isEmpty)
        #expect(session.live == nil)
    }

    @Test func outputTailDropsBlankLinesAndColour() {
        #expect(LivePreview.tail("a\n\n\u{1B}[1;31mb\u{1B}[0m\nc\nd\ne", limit: 3) == ["c", "d", "e"])
        #expect(LivePreview.tail("", limit: 3) == [])
    }
}

@Suite struct LivenessTests {
    @Test func deadSessionsAreReapedAfterGrace() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit", "alive"), at: t0)
        board.apply(try event("UserPromptSubmit", "dead"), at: t0)
        let gone = board.reap(at: t0.addingTimeInterval(120), grace: 90) { $0.id == "alive" }
        #expect(gone == ["dead"])
        #expect(Array(board.sessions.keys) == ["alive"])
    }

    @Test func recentSessionsSurviveEvenWithoutAProcess() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit", "new"), at: t0)
        #expect(board.reap(at: t0.addingTimeInterval(30), grace: 90) { _ in false }.isEmpty)
    }

    @Test func sessionsWithAHeldRequestSurvive() throws {
        var board = Board()
        board.apply(try event("PermissionRequest", "s1", ["tool_name": "Bash"]), at: t0)
        #expect(board.reap(at: t0.addingTimeInterval(600), grace: 90) { _ in false }.isEmpty)
    }

    @Test func sessionRemembersWhereItStarted() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit", "s1"), at: t0)
        board.apply(try HookEvent(["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/elsewhere",
                                   "tool_name": "Read"]), at: t0)
        #expect(board.sessions["s1"]?.cwd == "/work/agent-notch")
    }
}
