import Foundation
import Testing
@testable import AgentNotchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func event(_ name: String, _ extra: [String: Any] = [:]) throws -> HookEvent {
    try HookEvent(["hook_event_name": name, "session_id": "s1", "cwd": "/w/payments-api"].merging(extra) { $1 })
}

@Suite struct CheckResultTests {
    @Test(arguments: [
        ("./gradlew :api:test --tests '*Invoice*'", CheckResult.Kind.tests),
        ("cd ui && npm test", .tests),
        ("python3 -m pytest tests/", .tests),
        ("./gradlew :api:detekt", .lint),
        ("npx eslint src", .lint),
        ("swift build -c release", .build),
        ("FOO=1 make", .build),
    ] as [(String, CheckResult.Kind)])
    func recognisesRunners(command: String, kind: CheckResult.Kind) {
        #expect(CheckResult.kind(of: command) == kind)
    }

    @Test(arguments: ["grep -rn test src", "git commit -m 'add tests'", "echo build", "ls -la", "cat build.gradle"])
    func ignoresCommandsThatOnlyMentionTests(command: String) {
        #expect(CheckResult.kind(of: command) == nil)
    }

    @Test func failingOutputFailsEvenWithExitZero() throws {
        let result = try #require(CheckResult.classify(command: "npm test", output: "PASS a\nTests: 2 failed, 46 passed", failed: false))
        #expect(!result.passed)
        #expect(result.detail == "Tests: 2 failed, 46 passed")
        #expect(result.headline == "Tests failed")
    }

    @Test func passingRun() throws {
        let result = try #require(CheckResult.classify(command: "./gradlew build", output: "> Task :build\nBUILD SUCCESSFUL in 41s", failed: false))
        #expect(result.passed)
        #expect(result.detail == "BUILD SUCCESSFUL in 41s")
    }
}

@Suite struct TurnSummaryTests {
    @Test func countsFilesAndTheLastCheck() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("PostToolUse", ["tool_name": "Edit", "tool_use_id": "e1", "tool_input": [
            "file_path": "/w/A.kt", "old_string": "a", "new_string": "b\nc"]]), at: t0)
        board.apply(try event("PostToolUse", ["tool_name": "Write", "tool_use_id": "e2", "tool_input": [
            "file_path": "/w/B.kt", "content": "1\n2\n3"]]), at: t0)
        board.apply(try event("PostToolUse", ["tool_name": "Edit", "tool_use_id": "e3", "tool_input": [
            "file_path": "/w/A.kt", "old_string": "x", "new_string": "y"]]), at: t0)
        board.apply(try event("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "b1",
            "tool_input": ["command": "./gradlew test"], "error": "Exit code 1\nTests: 2 failed"]), at: t0)
        board.apply(try event("PostToolUse", ["tool_name": "Bash", "tool_use_id": "b2",
            "tool_input": ["command": "./gradlew test"], "tool_response": ["stdout": "BUILD SUCCESSFUL in 9s"]]), at: t0)
        let summary = try #require(board.sessions["s1"]?.summary)
        #expect(summary.files == ["/w/A.kt", "/w/B.kt"])
        #expect(summary.added == 2 + 3 + 1)
        #expect(summary.removed == 1 + 1)
        #expect(summary.check == CheckResult(kind: .tests, passed: true, detail: "BUILD SUCCESSFUL in 9s"))
    }

    @Test func failedEditsDontCountAndNewPromptsReset() throws {
        var board = Board()
        board.apply(try event("PostToolUseFailure", ["tool_name": "Edit", "tool_use_id": "e1", "tool_input": [
            "file_path": "/w/A.kt", "old_string": "a", "new_string": "b"], "error": "String not found"]), at: t0)
        #expect(board.sessions["s1"]?.summary.isEmpty == true)
        board.apply(try event("PostToolUse", ["tool_name": "Edit", "tool_use_id": "e2", "tool_input": [
            "file_path": "/w/A.kt", "old_string": "a", "new_string": "b"]]), at: t0)
        board.apply(try event("UserPromptSubmit"), at: t0)
        #expect(board.sessions["s1"]?.summary.isEmpty == true)
    }

    @Test func failedCommandOutputReachesThePreview() throws {
        var board = Board()
        board.apply(try event("PreToolUse", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "npm test"]]), at: t0)
        board.apply(try event("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "b1",
            "tool_input": ["command": "npm test"], "error": "Exit code 1\nTests: 2 failed, 5 passed"]), at: t0)
        #expect(board.sessions["s1"]?.live == .command("npm test", output: ["Tests: 2 failed, 5 passed"], finished: .failed))
    }
}

@Suite struct AgentListTests {
    private func open(_ id: String, idleHours: Double, busy: Bool = false) -> OpenSession {
        OpenSession(pid: 1, sessionId: id, cwd: "/w/payments-api", busy: busy,
                    startedAt: t0.addingTimeInterval(-idleHours * 3600 - 60),
                    statusSince: t0.addingTimeInterval(-idleHours * 3600))
    }

    @Test func quietForADayFoldsIntoOlder() {
        var board = Board()
        board.sync(open: [open("fresh", idleHours: 2), open("stale", idleHours: 30), open("busy", idleHours: 50, busy: true)], at: t0)
        let sections = board.listSections(at: t0)
        #expect(Set(sections.recent.map(\.id)) == ["fresh", "busy"])
        #expect(sections.older.map(\.id) == ["stale"])
    }

    @Test func filterSearchesNamesAndFolders() {
        var board = Board()
        board.sync(open: [open("a", idleHours: 1), open("b", idleHours: 40)], at: t0)
        board.setTabName("Search API", for: "a")
        board.setTitle("Scheduler design", for: "b")
        #expect(board.listSections(at: t0, filter: "sea").recent.map(\.id) == ["a"])
        #expect(board.listSections(at: t0, filter: "SCHEDULER").older.map(\.id) == ["b"])
        #expect(board.listSections(at: t0, filter: "payments").recent.count + board.listSections(at: t0, filter: "payments").older.count == 2)
    }
}
