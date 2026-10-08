import Foundation

public enum PermissionAnswer: Equatable, Sendable {
    case allow
    /// Allow, and save the suggested allow rules so Claude Code stops asking for this kind of call.
    case allowAlways
    case deny
    /// Give no decision: Claude Code falls back to its normal terminal prompt.
    case terminal
}

/// JSON bodies returned to Claude Code's HTTP hooks.
public enum HookReply {
    /// No decision, no context. Used for every non-blocking event.
    public static let empty = Data("{}".utf8)

    public static let denyMessage = "The user denied this request from AgentNotch."

    /// `rules` are the `updatedPermissions` entries for `.allowAlways` (`PermissionAsk.alwaysAllowRules`).
    public static func permission(_ answer: PermissionAnswer, rules: [JSONValue]) -> Data {
        var decision: [String: JSONValue]
        switch answer {
        case .terminal:
            return empty
        case .allow:
            decision = ["behavior": "allow"]
        case .allowAlways:
            decision = ["behavior": "allow"]
            if !rules.isEmpty { decision["updatedPermissions"] = .array(rules) }
        case .deny:
            decision = ["behavior": "deny", "message": .string(denyMessage)]
        }
        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string(HookEventName.permissionRequest),
                "decision": .object(decision),
            ]),
        ])
        return output.encoded()
    }
}

extension HookReply {
    /// Answers an `AskUserQuestion` from its PreToolUse hook: allow the call, with Claude's own
    /// input echoed back plus `answers` (question text → chosen label; multi-select labels joined
    /// with commas). `nil` gives no decision, so Claude Code asks in the terminal instead.
    public static func answers(_ answers: [String: String]?, to question: QuestionAsk) -> Data {
        guard let answers else { return empty }
        var input = question.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0) })
        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string(HookEventName.preToolUse),
                "permissionDecision": "allow",
                "updatedInput": .object(input),
            ]),
        ])
        return output.encoded()
    }
}

/// The Claude Code hook settings that point at this app.
public enum HookConfig {
    public static let port: UInt16 = 47823
    /// Every hook URL starts with this; the install scripts use it to find AgentNotch's entries.
    public static var base: String { "http://127.0.0.1:\(port)/" }
    public static var url: String { base + "hook" }
    /// AskUserQuestion's PreToolUse, held until the question is answered on the notch.
    public static var questionURL: String { base + "hook/question" }

    /// Progress events are answered immediately; a short timeout means a stuck app can never
    /// hold Claude up for long.
    public static let progressTimeout = 2
    /// Permission requests and questions wait for a click. When this runs out Claude Code shows
    /// its normal prompt.
    public static let permissionTimeout = 600

    public static let progressEvents = [
        HookEventName.sessionStart,
        HookEventName.sessionEnd,
        HookEventName.userPromptSubmit,
        HookEventName.preToolUse,
        HookEventName.postToolUse,
        HookEventName.postToolUseFailure,
        HookEventName.notification,
        HookEventName.stop,
        HookEventName.stopFailure,
        HookEventName.subagentStart,
        HookEventName.subagentStop,
    ]

    /// `{"hooks": {...}}`, ready for `claude --settings` or merging into `~/.claude/settings.json`.
    public static func settings() -> JSONValue {
        func group(url: String, timeout: Int, matcher: String? = nil) -> JSONValue {
            var group: [String: JSONValue] = ["hooks": .array([.object([
                "type": "http",
                "url": .string(url),
                "timeout": .number(Double(timeout)),
            ])])]
            if let matcher { group["matcher"] = .string(matcher) }
            return .object(group)
        }
        var hooks: [String: JSONValue] = [:]
        for event in progressEvents { hooks[event] = .array([group(url: url, timeout: progressTimeout)]) }
        hooks[HookEventName.preToolUse] = .array([
            group(url: url, timeout: progressTimeout),
            group(url: questionURL, timeout: permissionTimeout, matcher: "AskUserQuestion"),
        ])
        hooks[HookEventName.permissionRequest] = .array([group(url: url, timeout: permissionTimeout)])
        return .object(["hooks": .object(hooks)])
    }

    public static func settingsJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(settings())) ?? Data()) + Data("\n".utf8)
    }
}
