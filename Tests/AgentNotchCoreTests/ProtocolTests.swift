import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct HookEventTests {
    @Test func parsesCommonAndToolFields() throws {
        let json = """
        {"session_id":"abc","hook_event_name":"PreToolUse","cwd":"/w/p","tool_name":"Bash",
         "tool_input":{"command":"ls -la","timeout":120000},"permission_mode":"default"}
        """
        let event = try HookEvent(data: Data(json.utf8))
        #expect(event.name == "PreToolUse")
        #expect(event.sessionId == "abc")
        #expect(event.toolInput?["command"]?.string == "ls -la")
        #expect(event.toolInput?["timeout"] == .number(120000))
    }

    @Test func rejectsPayloadsWithoutRequiredFields() {
        #expect(throws: HookEventError.missingField("session_id")) {
            try HookEvent(data: Data(#"{"hook_event_name":"Stop"}"#.utf8))
        }
        #expect(throws: HookEventError.notAnObject) {
            try HookEvent(data: Data("[1,2]".utf8))
        }
    }
}

@Suite struct StepTests {
    @Test(arguments: [
        ("Read", ["file_path": "/a/Board.swift"], "Reading Board.swift"),
        ("Write", ["file_path": "/a/New.swift", "content": "a\nb"], "Writing New.swift"),
        ("Bash", ["command": "swift build -c release"], "Running swift build -c release"),
        ("Bash", ["command": "swift build", "description": "Build the app"], "Build the app"),
        ("Glob", ["pattern": "**/*.swift"], "Finding **/*.swift"),
        ("WebFetch", ["url": "https://code.claude.com/docs/en/hooks"], "Opening code.claude.com"),
        ("mcp__codegraph__codegraph_explore", [:], "Using codegraph: codegraph explore"),
        ("SomethingNew", [:], "Using SomethingNew"),
    ] as [(String, [String: String], String)])
    func describesTools(tool: String, input: [String: String], expected: String) {
        let json = JSONValue.object(input.mapValues { .string($0) })
        #expect(Step.describe(tool: tool, input: json).text == expected)
    }

    @Test func editCountsIgnoreSharedContext() {
        let step = Step.describe(tool: "Edit", input: .object([
            "file_path": "/a/x.swift", "old_string": "keep\nold\nkeep2", "new_string": "keep\nnew1\nnew2\nkeep2",
        ]))
        #expect(step.added == 2)
        #expect(step.removed == 1)
    }

    @Test func oneLineTruncates() {
        #expect(Step.oneLine("short", max: 10) == "short")
        #expect(Step.oneLine("0123456789abc", max: 10) == "012345678…")
        #expect(Step.oneLine("first\nsecond", max: 20) == "first …")
    }
}

@Suite struct DiffPreviewTests {
    @Test func showsOnlyChangedLines() {
        let preview = DiffPreview.lines(old: "a\nb\nc", new: "a\nx\nc", limit: 8)
        #expect(preview.lines == [.init(kind: .removed, text: "b"), .init(kind: .added, text: "x")])
        #expect(preview.hidden == 0)
    }

    @Test func largeChangesKeepBothSides() {
        let old = (1...10).map { "old\($0)" }.joined(separator: "\n")
        let new = (1...10).map { "new\($0)" }.joined(separator: "\n")
        let preview = DiffPreview.lines(old: old, new: new, limit: 8)
        #expect(preview.lines.count == 8)
        #expect(preview.lines.filter { $0.kind == .removed }.count == 4)
        #expect(preview.lines.filter { $0.kind == .added }.count == 4)
        #expect(preview.hidden == 12)
    }

    @Test func sharedIndentationIsDropped() {
        let preview = DiffPreview.lines(old: "        if a {", new: "        // why\n        if b {\n            go()", limit: 8)
        #expect(preview.lines.map(\.text) == ["if a {", "// why", "if b {", "    go()"])
    }

    @Test func newFileIsAllAdded() {
        let preview = DiffPreview.lines(old: "", new: "a\nb", limit: 8)
        #expect(preview.lines.map(\.kind) == [.added, .added])
    }
}

@Suite struct HTTPParserTests {
    private func request(_ body: String, headers: String? = nil) -> Data {
        let head = headers ?? "Content-Length: \(body.utf8.count)\r\n"
        return Data("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\(head)\r\n\(body)".utf8)
    }

    @Test func parsesContentLengthBody() {
        guard case .complete(let request) = HTTPParser.parse(request(#"{"a":1}"#)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/hook")
        #expect(request.headers["content-type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"a":1}"#)
    }

    @Test func waitsForTheRestOfTheBody() {
        let full = request(#"{"hello":"world"}"#)
        #expect(HTTPParser.parse(full.prefix(20)) == .incomplete(expectedTotal: nil))
        #expect(HTTPParser.parse(full.dropLast(3)) == .incomplete(expectedTotal: full.count))
    }

    @Test func decodesChunkedBodies() {
        let chunked = "7\r\n{\"a\":1}\r\n2\r\n  \r\n0\r\n\r\n"
        let data = request(chunked, headers: "Transfer-Encoding: chunked\r\n")
        guard case .complete(let request) = HTTPParser.parse(data) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"a\":1}  ")
        #expect(HTTPParser.parse(data.dropLast(7)) == .incomplete(expectedTotal: nil))
    }

    @Test func rejectsGarbage() {
        guard case .invalid = HTTPParser.parse(Data("NONSENSE\r\n\r\n".utf8)) else {
            Issue.record("expected invalid")
            return
        }
    }

    @Test func dropsQueryString() {
        guard case .complete(let request) = HTTPParser.parse(Data("GET /health?x=1 HTTP/1.1\r\n\r\n".utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.path == "/health")
    }
}

@Suite struct HookReplyTests {
    private func decision(_ data: Data) throws -> JSONValue? {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["hookSpecificOutput"]?["hookEventName"]?.string == "PermissionRequest")
        return json["hookSpecificOutput"]?["decision"]
    }

    @Test func allow() throws {
        #expect(try decision(HookReply.permission(.allow, rules: [])) == .object(["behavior": "allow"]))
    }

    @Test func allowAlwaysEchoesSuggestions() throws {
        let suggestion: JSONValue = .object(["type": "addRules", "behavior": "allow",
                                             "rules": .array([.object(["toolName": "Bash", "ruleContent": "npm test:*"])])])
        let reply = try decision(HookReply.permission(.allowAlways, rules: [suggestion]))
        #expect(reply?["behavior"]?.string == "allow")
        #expect(reply?["updatedPermissions"] == .array([suggestion]))
    }

    @Test func denyExplainsWhy() throws {
        let reply = try decision(HookReply.permission(.deny, rules: []))
        #expect(reply?["behavior"]?.string == "deny")
        #expect(reply?["message"]?.string == HookReply.denyMessage)
    }

    @Test func questionAnswersEchoTheInput() throws {
        var board = Board()
        let input: [String: Any] = ["questions": [[
            "question": "Which framework?", "header": "Framework", "multiSelect": false,
            "options": [["label": "React", "description": "Component library"], ["label": "Vue", "description": "Progressive"]],
        ]]]
        let asked = board.askQuestion(try HookEvent([
            "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "AskUserQuestion", "tool_input": input,
        ]), at: Date())
        let question = try #require(asked)
        let json = try JSONDecoder().decode(JSONValue.self, from: HookReply.answers(["Which framework?": "React"], to: question))
        let output = try #require(json["hookSpecificOutput"])
        #expect(output["hookEventName"]?.string == "PreToolUse")
        #expect(output["permissionDecision"]?.string == "allow")
        #expect(output["updatedInput"]?["answers"] == .object(["Which framework?": "React"]))
        #expect(output["updatedInput"]?["questions"] == question.input["questions"])
        #expect(HookReply.answers(nil, to: question) == HookReply.empty)
    }

    @Test func terminalGivesNoDecision() {
        #expect(HookReply.permission(.terminal, rules: []) == HookReply.empty)
    }
}

@Suite struct HookConfigTests {
    @Test func everyEventPointsAtTheApp() throws {
        let hooks = try #require(HookConfig.settings()["hooks"]?.object)
        #expect(hooks.count == HookConfig.progressEvents.count + 1)
        for (event, groups) in hooks {
            let handler = try #require(groups.array?.first?["hooks"]?.array?.first)
            #expect(handler["type"]?.string == "http")
            #expect(handler["url"]?.string == "http://127.0.0.1:47823/hook")
            let timeout = event == "PermissionRequest" ? HookConfig.permissionTimeout : HookConfig.progressTimeout
            #expect(handler["timeout"] == .number(Double(timeout)), "\(event)")
        }
    }

    /// AskUserQuestion gets a second, held PreToolUse hook on its own path.
    @Test func questionsHaveTheirOwnHeldHook() throws {
        let groups = try #require(HookConfig.settings()["hooks"]?["PreToolUse"]?.array)
        #expect(groups.count == 2)
        let question = try #require(groups.first { $0["matcher"]?.string == "AskUserQuestion" })
        let handler = try #require(question["hooks"]?.array?.first)
        #expect(handler["url"]?.string == "http://127.0.0.1:47823/hook/question")
        #expect(handler["timeout"] == .number(Double(HookConfig.permissionTimeout)))
        #expect(HookConfig.questionURL.hasPrefix(HookConfig.base) && HookConfig.url.hasPrefix(HookConfig.base))
    }

    /// `hooks.json` in the repo is generated by `AgentNotch hooks`; keep it in sync.
    @Test func checkedInHooksFileIsCurrent() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try Data(contentsOf: repo.appendingPathComponent("hooks.json"))
        #expect(file == HookConfig.settingsJSON(), "run: swift run AgentNotch hooks > hooks.json")
    }
}

@Suite struct JSONValueTests {
    @Test func roundTripsIntegersAsIntegers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"n":3,"f":1.5,"b":true,"x":null}"#.utf8))
        #expect(String(decoding: value.encoded(), as: UTF8.self) == #"{"b":true,"f":1.5,"n":3,"x":null}"#)
    }
}
