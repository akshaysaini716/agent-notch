import AgentNotchCore
import AppKit
import SwiftUI

/// Renders each UI state to a PNG, so the design can be reviewed without driving the real notch.
@MainActor
enum Snapshot {
    struct Scenario {
        let name: String
        let mode: NotchMode
        let events: [[String: Any]]
        var focus: String? = nil
        /// Idle agents found through Claude Code's session files, with what their transcripts say.
        var idle: [(OpenSession, title: String, digest: TranscriptDigest)] = []
        /// Claude's final reply per session, as the transcript would give it.
        var reply: [String: String] = [:]
        /// Opened with the hotkey (shows the key hints).
        var keyboard = false
        var search = ""
        var showOlder = false
    }

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scenario in scenarios {
            let model = NotchModel()
            model.geometry = NotchGeometry(hasNotch: true, width: 185, height: 32)
            model.forcedMode = scenario.mode
            var board = Board()
            let start = Date().addingTimeInterval(-134)
            for (index, fields) in scenario.events.enumerated() {
                guard let event = try? HookEvent(fields) else {
                    print("bad fixture in \(scenario.name)")
                    return 1
                }
                // The last event in each scenario is "now"; earlier ones are spread over the turn.
                let at = index == scenario.events.count - 1 ? Date() : start.addingTimeInterval(Double(index))
                if event.toolName == "AskUserQuestion" {
                    _ = board.askQuestion(event, at: at)   // what the held question hook does
                } else {
                    board.apply(event, at: at)
                }
            }
            board.sync(open: scenario.idle.map(\.0), at: Date())
            for (open, title, digest) in scenario.idle {
                board.setTitle(title, for: open.sessionId)
                board.apply(digest, to: open.sessionId)
            }
            for (session, title) in titles { board.setTitle(title, for: session) }
            for (session, reply) in scenario.reply { board.apply(TranscriptDigest(lastReply: reply), to: session) }
            model.load(board)
            if let focus = scenario.focus { model.focus(focus) }
            model.keyboardOpen = scenario.keyboard
            model.showOlder = scenario.showOlder
            if !scenario.search.isEmpty { model.search(scenario.search) }

            let view = Backdrop { NotchContent() }.environmentObject(model)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("could not render \(scenario.name)")
                return 1
            }
            let file = directory.appendingPathComponent("\(scenario.name).png")
            do { try png.write(to: file) } catch {
                print("could not write \(file.path): \(error)")
                return 1
            }
            print(file.path)
        }
        return 0
    }

    /// A stand-in desktop and menu bar behind the notch.
    private struct Backdrop<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.33, green: 0.40, blue: 0.52), Color(red: 0.70, green: 0.62, blue: 0.66)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 32)
                content
            }
            .frame(width: 780, height: 470)
        }
    }

    // MARK: - Fixtures

    private static func event(_ name: String, _ session: String, _ cwd: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["hook_event_name": name, "session_id": session, "cwd": cwd].merging(extra) { $1 }
    }

    private static func tool(_ session: String, _ cwd: String, _ id: String, _ name: String, _ input: [String: Any],
                             response: Any? = nil, agent: String? = nil) -> [[String: Any]] {
        var pre: [String: Any] = ["tool_name": name, "tool_input": input, "tool_use_id": id]
        if let agent { pre["agent_type"] = agent }
        var events = [event("PreToolUse", session, cwd, pre)]
        if let response {
            events.append(event("PostToolUse", session, cwd, ["tool_name": name, "tool_use_id": id, "tool_response": response]))
        }
        return events
    }

    /// Titles as Claude would have written them into each transcript.
    private static let titles = [
        "a": "Fix invoice rounding",
        "b": "Notch agent monitor",
        "c": "Bigger banner font",
    ]

    private nonisolated static let platform = "/Users/me/code/payments-api"
    private nonisolated static let notch = "/Users/me/code/agent-notch"
    private nonisolated static let plane = "/Users/me/code/claude-plane"

    /// agent-notch is mid-edit, payments-api is running tests, claude-plane has finished.
    private static let threeSessions: [[String: Any]] = {
        var events: [[String: Any]] = [
            event("UserPromptSubmit", "c", plane, ["prompt": "Make the banner font bigger"]),
        ]
        events += tool("c", plane, "c1", "Edit", ["file_path": "\(plane)/Sources/Flight.swift",
                                                  "old_string": "size: 13", "new_string": "size: 15"], response: [:])
        events.append(event("Stop", "c", plane))
        events.append(event("UserPromptSubmit", "a", platform, ["prompt": "Fix the invoice rounding"]))
        events += tool("a", platform, "a1", "Grep", ["pattern": "roundTotal"], response: [:])
        events += tool("a", platform, "a2", "Read", ["file_path": "\(platform)/api/src/InvoiceTotals.kt"], response: [:])
        events += tool("a", platform, "a3", "Bash", ["command": "./gradlew :api:test --tests '*Invoice*'",
                                                     "description": "Run the invoice tests"],
                       response: ["stdout": "> Task :api:test\nInvoiceTotalsTest > roundsHalfUp() PASSED\nInvoiceTotalsTest > keepsCurrency() PASSED\nBUILD SUCCESSFUL in 41s",
                                  "stderr": "", "interrupted": false])
        events += tool("a", platform, "a4", "Bash", ["command": "./gradlew :api:detekt", "description": "Run detekt"])
        events.append(event("UserPromptSubmit", "b", notch, ["prompt": "Add a hover delay to the notch"]))
        events += tool("b", notch, "b1", "Read", ["file_path": "\(notch)/Sources/AgentNotch/NotchController.swift"], response: [:])
        events += tool("b", notch, "b2", "Grep", ["pattern": "outsideTicks"], response: [:])
        events += tool("b", notch, "b3", "Edit", [
            "file_path": "\(notch)/Sources/AgentNotch/NotchController.swift",
            "old_string": "        } else {\n            outsideTicks += 1\n            if outsideTicks >= 3 { model.setHovering(false) }",
            "new_string": "        } else {\n            outsideTicks += 1\n            // Grace period before folding away.\n            if outsideTicks >= hoverGrace { model.setHovering(false) }",
        ])
        return events
    }()

    /// Agents that were already open and idle when the notch started.
    private static let idleAgents: [(OpenSession, title: String, digest: TranscriptDigest)] = {
        func open(_ id: String, hoursAgo: Double, idleMinutes: Double) -> OpenSession {
            OpenSession(pid: 1, sessionId: id, cwd: platform, busy: false,
                        startedAt: Date().addingTimeInterval(-hoursAgo * 3600),
                        statusSince: Date().addingTimeInterval(-idleMinutes * 60))
        }
        return [
            (open("i1", hoursAgo: 30, idleMinutes: 190), "Spark job failing on the staging cluster",
             TranscriptDigest(prompt: "why is the nightly spark job failing on staging", steps: [],
                              lastReply: "The driver pod is OOMKilled: spark.driver.memory is 1g but the job collects a 3 GB DataFrame. Raise it to 4g or avoid collect().")),
            (open("i2", hoursAgo: 52, idleMinutes: 1500), "Debug the catalog connection error",
             TranscriptDigest(prompt: "catalog says connection refused", lastReply: "Fixed: the base URL had a trailing /v1/, so requests went to /v1/v1/config.")),
            (open("i3", hoursAgo: 75, idleMinutes: 2900), "Check ingress rate limits", TranscriptDigest()),
            (open("i4", hoursAgo: 99, idleMinutes: 4400), "Draft the release notes", TranscriptDigest()),
        ]
    }()

    static let scenarios: [Scenario] = [
        Scenario(name: "0-list-idle-selected", mode: .expanded, events: threeSessions, focus: "i1", idle: idleAgents),
        Scenario(name: "0b-keyboard-list", mode: .expanded, events: threeSessions, focus: "b", idle: idleAgents, keyboard: true),
        Scenario(name: "0c-older-open", mode: .expanded, events: threeSessions, focus: "b", idle: idleAgents, showOlder: true),
        Scenario(name: "0d-search", mode: .expanded, events: threeSessions, idle: idleAgents, keyboard: true, search: "spark"),
        Scenario(name: "1-collapsed", mode: .collapsed, events: threeSessions),
        Scenario(name: "2-focus-edit", mode: .expanded, events: threeSessions, focus: "b", idle: idleAgents),
        Scenario(name: "3-focus-command", mode: .expanded, events: threeSessions, focus: "a", idle: idleAgents),
        Scenario(name: "4-focus-done", mode: .expanded, events: Array(threeSessions.prefix(4))),
        Scenario(name: "5-permission-bash", mode: .expanded, events: threeSessions + [
            event("PermissionRequest", "a", platform, [
                "tool_name": "Bash",
                "tool_input": ["command": "kubectl -n staging delete pod api-worker-0",
                               "description": "Restart the worker pod"],
                "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                            "rules": [["toolName": "Bash", "ruleContent": "kubectl -n staging delete pod *"]]]],
            ]),
        ]),
        Scenario(name: "5b-permission-keyboard", mode: .expanded, events: threeSessions + [
            event("PermissionRequest", "a", platform, [
                "tool_name": "Bash",
                "tool_input": ["command": "kubectl -n staging delete pod api-worker-0",
                               "description": "Restart the worker pod"],
                "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                            "rules": [["toolName": "Bash", "ruleContent": "kubectl -n staging delete pod *"]]]],
            ]),
        ], keyboard: true),
        Scenario(name: "6-permission-edit", mode: .expanded, events: threeSessions + [
            event("PermissionRequest", "b", notch, [
                "tool_name": "Edit",
                "tool_input": ["file_path": "\(notch)/Sources/AgentNotch/Theme.swift",
                               "old_string": "static let expandedWidth: CGFloat = 440\nstatic let earWidth: CGFloat = 38",
                               "new_string": "static let expandedWidth: CGFloat = 560\nstatic let earWidth: CGFloat = 46"],
            ]),
            event("PermissionRequest", "a", platform, ["tool_name": "Bash", "tool_input": ["command": "git push"]]),
        ]),
        Scenario(name: "7-question", mode: .expanded, events: [
            event("UserPromptSubmit", "b", notch, ["prompt": "Ship it"]),
            event("PreToolUse", "b", notch, ["tool_name": "AskUserQuestion", "tool_input": ["questions": [
                ["question": "Which branch should the PR target?", "header": "Base branch", "multiSelect": false,
                 "options": [["label": "development", "description": "Shared integration branch; what most PRs target"],
                             ["label": "release/5.0", "description": "Only for fixes going into the 5.0 release"],
                             ["label": "main", "description": ""]]],
                ["question": "Which checks should run first?", "header": "Checks", "multiSelect": true,
                 "options": [["label": "Unit tests", "description": ""], ["label": "Lint", "description": ""]]],
            ]]]),
        ]),
        Scenario(name: "8-empty", mode: .expanded, events: []),
        Scenario(name: "9-done-notice", mode: .expanded, events: [
            event("UserPromptSubmit", "a", platform, ["prompt": "Fix the invoice rounding"]),
            event("PostToolUse", "a", platform, ["tool_name": "Edit", "tool_use_id": "z0", "tool_input": [
                "file_path": "\(platform)/api/InvoiceTotals.kt", "old_string": "a\nb", "new_string": "c\nd\ne"]]),
            event("PostToolUse", "a", platform, ["tool_name": "Edit", "tool_use_id": "z2", "tool_input": [
                "file_path": "\(platform)/api/Currency.kt", "old_string": "x", "new_string": "y\nz"]]),
            event("PreToolUse", "a", platform, ["tool_name": "Bash", "tool_use_id": "z1",
                                                "tool_input": ["command": "./gradlew :api:test", "description": "Run the tests"]]),
            event("PostToolUse", "a", platform, ["tool_name": "Bash", "tool_use_id": "z1",
                                                 "tool_input": ["command": "./gradlew :api:test"],
                                                 "tool_response": ["stdout": "312 tests completed\nBUILD SUCCESSFUL in 41s"]]),
            event("Stop", "a", platform),
        ], idle: [], reply: ["a": "Totals now round half-up per line before summing. 312 tests pass; nothing deployed yet."]),
    ]
}
