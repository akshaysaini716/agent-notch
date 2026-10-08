import Foundation

/// One tool call in a session's recent history, for the step checklist.
public struct StepRecord: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, done, failed }

    /// `tool_use_id` when Claude Code sends one, so the matching PostToolUse can close it.
    public let id: String
    public let tool: String
    public var step: Step
    public var state: State
}

/// What the agent is touching right now, shown next to the checklist: the diff it is making,
/// the command it is running and its output, or a one-line description.
public enum LivePreview: Equatable, Sendable {
    case diff(file: String, lines: [DiffPreview.Line], hidden: Int, added: Int, removed: Int)
    /// `output` is filled in by the PostToolUse; `finished` is nil while the command runs.
    case command(String, output: [String], finished: Outcome?)
    case text(symbol: String, text: String)

    public enum Outcome: Equatable, Sendable { case succeeded, failed }

    public static let diffLimit = 5
    public static let outputLimit = 4

    /// The preview for a tool call that is about to run, or nil to keep the previous one.
    public static func starting(tool: String, input: JSONValue?) -> LivePreview? {
        let input = input ?? .object([:])
        switch tool {
        case "Edit", "MultiEdit":
            let old = input["old_string"]?.string ?? "", new = input["new_string"]?.string ?? ""
            return diff(file: Step.fileName(input["file_path"]), old: old, new: new)
        case "Write":
            return diff(file: Step.fileName(input["file_path"]), old: "", new: input["content"]?.string ?? "")
        case "Bash":
            return .command(input["command"]?.string ?? "", output: [], finished: nil)
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "AskUserQuestion":
            return nil
        default:
            let step = Step.describe(tool: tool, input: input)
            return .text(symbol: step.symbol, text: step.text)
        }
    }

    /// What a finished command printed: stdout/stderr on success, the error text (minus its
    /// "Exit code N" line) on failure.
    public static func output(response: JSONValue?, error: String?) -> String {
        if let error {
            return error.split(separator: "\n", omittingEmptySubsequences: false)
                .drop { $0.hasPrefix("Exit code") }.joined(separator: "\n")
        }
        if let text = response?.string { return text }
        return [response?["stdout"]?.string, response?["stderr"]?.string]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Adds a finished Bash call's output to its command preview.
    public func finishing(response: JSONValue?, failed: Bool, error: String? = nil) -> LivePreview {
        guard case .command(let command, _, _) = self else { return self }
        let output = LivePreview.output(response: response, error: error)
        let interrupted = response?["interrupted"]?.bool ?? false
        return .command(command, output: LivePreview.tail(output, limit: LivePreview.outputLimit),
                        finished: failed || interrupted ? .failed : .succeeded)
    }

    static func diff(file: String, old: String, new: String) -> LivePreview {
        let preview = DiffPreview.lines(old: old, new: new, limit: diffLimit)
        let (added, removed) = Step.editCounts(old: old, new: new)
        return .diff(file: file, lines: preview.lines, hidden: preview.hidden, added: added ?? 0, removed: removed ?? 0)
    }

    /// Last non-empty lines of command output, without terminal colour codes.
    public static func tail(_ output: String, limit: Int) -> [String] {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(limit).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
    }
}

/// Progress through the agent's own task list, when it keeps one (TodoWrite).
public struct TaskProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    init?(todos: JSONValue?) {
        guard let todos = todos?.array, !todos.isEmpty else { return nil }
        total = todos.count
        done = todos.filter { $0["status"]?.string == "completed" }.count
    }
}
