import Foundation

/// The hook events AgentNotch subscribes to (names as Claude Code sends them in `hook_event_name`).
public enum HookEventName {
    public static let sessionStart = "SessionStart"
    public static let sessionEnd = "SessionEnd"
    public static let userPromptSubmit = "UserPromptSubmit"
    public static let preToolUse = "PreToolUse"
    public static let postToolUse = "PostToolUse"
    public static let postToolUseFailure = "PostToolUseFailure"
    public static let permissionRequest = "PermissionRequest"
    public static let notification = "Notification"
    public static let stop = "Stop"
    public static let stopFailure = "StopFailure"
    public static let subagentStart = "SubagentStart"
    public static let subagentStop = "SubagentStop"
}

public enum HookEventError: Error, Equatable {
    case notAnObject
    case missingField(String)
}

/// One hook payload posted by Claude Code. Only the fields AgentNotch renders are lifted out;
/// the full payload stays in `raw`.
public struct HookEvent: Equatable, Sendable {
    public var name: String
    public var sessionId: String
    public var cwd: String?
    /// The session's JSONL transcript; its title lives there.
    public var transcriptPath: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    /// Pairs a PreToolUse with its PostToolUse.
    public var toolUseId: String?
    /// PostToolUse only: what the tool returned (Bash: stdout/stderr).
    public var toolResponse: JSONValue?
    /// PostToolUseFailure only: e.g. "Exit code 1\n<output>" for a failing command.
    public var error: String?
    public var prompt: String?
    public var message: String?
    public var notificationType: String?
    public var agentType: String?
    public var permissionSuggestions: [JSONValue]
    public var raw: JSONValue

    public init(data: Data) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        guard raw.object != nil else { throw HookEventError.notAnObject }
        guard let name = raw["hook_event_name"]?.string else { throw HookEventError.missingField("hook_event_name") }
        guard let sessionId = raw["session_id"]?.string else { throw HookEventError.missingField("session_id") }
        self.name = name
        self.sessionId = sessionId
        self.cwd = raw["cwd"]?.string
        self.transcriptPath = raw["transcript_path"]?.string
        self.toolName = raw["tool_name"]?.string
        self.toolInput = raw["tool_input"]
        self.toolUseId = raw["tool_use_id"]?.string
        self.toolResponse = raw["tool_response"]
        self.error = raw["error"]?.string
        self.prompt = raw["prompt"]?.string
        self.message = raw["message"]?.string
        self.notificationType = raw["notification_type"]?.string
        self.agentType = raw["agent_type"]?.string
        self.permissionSuggestions = raw["permission_suggestions"]?.array ?? []
        self.raw = raw
    }

    /// Builds an event from a dictionary literal (fixtures, snapshots).
    public init(_ dictionary: [String: Any]) throws {
        try self.init(data: JSONSerialization.data(withJSONObject: dictionary))
    }
}
