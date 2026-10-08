import Foundation
import Testing
@testable import AgentNotchCore

private func event(_ name: String, _ session: String = "s1", _ extra: [String: Any] = [:]) throws -> HookEvent {
    try HookEvent(["hook_event_name": name, "session_id": session, "cwd": "/work/payments-api"].merging(extra) { $1 })
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct BoardTests {
    @Test func promptStartsATurn() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit", "s1", ["prompt": "Fix the build\nand the tests"]), at: t0)
        let session = try #require(board.sessions["s1"])
        #expect(session.project == "payments-api")
        #expect(session.status == .working)
        #expect(session.step == .thinking)
        #expect(session.prompt == "Fix the build …")
        #expect(session.turnStartedAt == t0)
        #expect(board.isActive(at: t0))
    }

    @Test func toolCallsBecomeSteps() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Read", "tool_input": ["file_path": "/a/b/Board.swift"]]), at: t0)
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Grep", "tool_input": ["pattern": "TODO"],
                                                   "agent_type": "Explore"]), at: t0)
        let session = try #require(board.sessions["s1"])
        #expect(session.step?.text == "Searching for “TODO”")
        #expect(session.steps == 2)
        #expect(session.subagent == "Explore")
    }

    @Test func stopFinishesThenFoldsAway() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("Stop"), at: t0.addingTimeInterval(30))
        let session = try #require(board.sessions["s1"])
        #expect(session.status == .done)
        #expect(session.turnEndedAt == t0.addingTimeInterval(30))
        #expect(board.isActive(at: t0.addingTimeInterval(31)))
        #expect(!board.isActive(at: t0.addingTimeInterval(30 + Board.doneFlash + 1)))
    }

    @Test func sessionEndRemovesEverything() throws {
        var board = Board()
        board.apply(try event("PermissionRequest", "s1", ["tool_name": "Bash", "tool_input": ["command": "ls"]]), at: t0)
        board.apply(try event("SessionEnd"), at: t0)
        #expect(board.sessions.isEmpty)
        #expect(board.attention.isEmpty)
    }

    @Test func permissionRequestIsHeldUntilResolved() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        let suggestion: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                         "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]]
        let ask = try #require(board.apply(try event("PermissionRequest", "s1", [
            "tool_name": "Bash", "tool_input": ["command": "npm test"], "permission_suggestions": [suggestion],
        ]), at: t0))
        #expect(ask.toolName == "Bash")
        #expect(ask.suggestions.count == 1)
        #expect(board.sessions["s1"]?.status == .needsYou)
        #expect(board.attention.map(\.id) == [ask.id])

        board.resolve(ask.id, at: t0)
        #expect(board.attention.isEmpty)
        #expect(board.sessions["s1"]?.status == .working)
    }

    /// Real suggestions captured from Claude Code 2.1.294: a project command gets an allow rule,
    /// a command outside the project gets a directory grant plus a mode switch.
    @Test func alwaysAllowOnlyCarriesAllowRules() throws {
        var board = Board()
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test *"]],
                                   "behavior": "allow", "destination": "localSettings"]
        let modeSwitch: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        let directory: [String: Any] = ["type": "addDirectories", "directories": ["/tmp/x"], "destination": "session"]
        let ask = try #require(board.apply(try event("PermissionRequest", "s1", [
            "tool_name": "Bash", "permission_suggestions": [directory, rule, modeSwitch],
        ]), at: t0))
        #expect(ask.alwaysAllowRules.count == 1)
        #expect(ask.alwaysAllowRules.first?["type"]?.string == "addRules")
        #expect(ask.alwaysAllowSummary == "Bash(npm test *)")

        let outside = try #require(board.apply(try event("PermissionRequest", "s2", [
            "tool_name": "Bash", "permission_suggestions": [directory, modeSwitch],
        ]), at: t0))
        #expect(outside.alwaysAllowRules.isEmpty)
        #expect(outside.alwaysAllowSummary == nil)
    }

    @Test func requestsQueueOldestFirstAcrossSessions() throws {
        var board = Board()
        let first = try #require(board.apply(try event("PermissionRequest", "a", ["tool_name": "Bash"]), at: t0))
        let second = try #require(board.apply(try event("PermissionRequest", "b", ["tool_name": "Write"]), at: t0))
        #expect(board.attention.map(\.id) == [first.id, second.id])
        board.resolve(first.id, at: t0)
        #expect(board.sessions["a"]?.status == .working)
        #expect(board.sessions["b"]?.status == .needsYou)
    }

    @Test func toolEventsDoNotClearAPendingRequest() throws {
        var board = Board()
        board.apply(try event("PermissionRequest", "s1", ["tool_name": "Bash"]), at: t0)
        // A subagent in the same session keeps working meanwhile.
        board.apply(try event("PreToolUse", "s1", ["tool_name": "Read", "tool_input": ["file_path": "/x"]]), at: t0)
        board.apply(try event("PostToolUse", "s1", ["tool_name": "Read"]), at: t0)
        #expect(board.sessions["s1"]?.status == .needsYou)
    }

    @Test func askUserQuestionShowsACardUntilAnswered() throws {
        var board = Board()
        let input: [String: Any] = ["questions": [[
            "question": "Which branch?", "header": "Branch", "multiSelect": false,
            "options": [["label": "development", "description": "Shared dev"], ["label": "main", "description": ""]],
        ]]]
        let pre = try event("PreToolUse", "s1", ["tool_name": "AskUserQuestion", "tool_input": input])
        // The progress hook only records the step; the held question hook makes the card.
        board.apply(pre, at: t0)
        #expect(board.attention.isEmpty)
        let asked = board.askQuestion(pre, at: t0)
        let question = try #require(asked)
        #expect(question.questions.first?.options == [.init(label: "development", description: "Shared dev"),
                                                       .init(label: "main", description: nil)])
        #expect(board.attention.map(\.id) == [question.id])
        #expect(board.sessions["s1"]?.status == .needsYou)

        board.resolve(question.id, at: t0)
        #expect(board.attention.isEmpty)
        #expect(board.sessions["s1"]?.status == .working)
    }

    @Test func questionWithoutOptionsIsLeftToTheTerminal() throws {
        var board = Board()
        let pre = try event("PreToolUse", "s1", ["tool_name": "AskUserQuestion",
                                                 "tool_input": ["questions": [["question": "Free text?", "options": []]]]])
        let noOptions = board.askQuestion(pre, at: t0)
        let notAQuestion = board.askQuestion(try event("PreToolUse", "s1", ["tool_name": "Bash"]), at: t0)
        #expect(noOptions == nil)
        #expect(notAQuestion == nil)
    }

    @Test func terminalPromptMarksSessionWithoutACard() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("Notification", "s1", ["notification_type": "permission_prompt",
                                                     "message": "Claude needs your permission to use Bash"]), at: t0)
        #expect(board.sessions["s1"]?.status == .needsYou)
        #expect(board.sessions["s1"]?.notice == "Claude needs your permission to use Bash")
        #expect(board.attention.isEmpty)

        board.apply(try event("PostToolUse", "s1", ["tool_name": "Bash"]), at: t0)
        #expect(board.sessions["s1"]?.status == .working)
        #expect(board.sessions["s1"]?.notice == nil)
    }

    @Test func idleNotificationIsIgnored() throws {
        var board = Board()
        board.apply(try event("Stop"), at: t0)
        board.apply(try event("Notification", "s1", ["notification_type": "idle_prompt"]), at: t0)
        #expect(board.sessions["s1"]?.status == .done)
    }

    @Test func newPromptClearsLeftoverCards() throws {
        var board = Board()
        _ = board.askQuestion(try event("PreToolUse", "s1", ["tool_name": "AskUserQuestion", "tool_input": [
            "questions": [["question": "Ok?", "options": [["label": "Yes"]]]]]]), at: t0)
        #expect(board.attention.count == 1)
        board.apply(try event("UserPromptSubmit"), at: t0)
        #expect(board.attention.isEmpty)
    }

    @Test func staleSessionsArePruned() throws {
        var board = Board()
        board.apply(try event("Stop", "old"), at: t0)
        board.apply(try event("Stop", "new"), at: t0.addingTimeInterval(Board.staleAfter))
        board.prune(at: t0.addingTimeInterval(Board.staleAfter + 1))
        #expect(Array(board.sessions.keys) == ["new"])
    }

    @Test func rowsKeepFirstSeenOrder() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit", "b"), at: t0)
        board.apply(try event("UserPromptSubmit", "a"), at: t0.addingTimeInterval(1))
        board.apply(try event("PreToolUse", "b", ["tool_name": "Read"]), at: t0.addingTimeInterval(2))
        #expect(board.orderedSessions.map(\.id) == ["a", "b"])   // newest first
    }
}
