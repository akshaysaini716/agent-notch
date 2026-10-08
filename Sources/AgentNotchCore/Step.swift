import Foundation

/// What an agent is doing right now, phrased for a person glancing at the notch.
public struct Step: Equatable, Sendable {
    /// SF Symbol name.
    public var symbol: String
    public var text: String
    /// Line counts for file edits (`+added −removed`), when known.
    public var added: Int?
    public var removed: Int?

    public init(symbol: String, text: String, added: Int? = nil, removed: Int? = nil) {
        self.symbol = symbol
        self.text = text
        self.added = added
        self.removed = removed
    }

    public static let thinking = Step(symbol: "sparkle", text: "Thinking")

    public static func describe(tool: String, input: JSONValue?) -> Step {
        let input = input ?? .object([:])
        switch tool {
        case "Read":
            return Step(symbol: "doc.text", text: "Reading \(fileName(input["file_path"]))")
        case "Edit", "MultiEdit":
            let (added, removed) = editCounts(old: input["old_string"]?.string, new: input["new_string"]?.string)
            return Step(symbol: "pencil", text: "Editing \(fileName(input["file_path"]))", added: added, removed: removed)
        case "Write":
            return Step(symbol: "square.and.pencil", text: "Writing \(fileName(input["file_path"]))",
                        added: input["content"]?.string.map(lineCount))
        case "NotebookEdit":
            return Step(symbol: "pencil", text: "Editing \(fileName(input["notebook_path"]))")
        case "Bash":
            // Claude's own description ("Run the tests") already reads as a step.
            if let description = input["description"]?.string, !description.isEmpty {
                return Step(symbol: "terminal", text: oneLine(description, max: 70))
            }
            return Step(symbol: "terminal", text: "Running \(oneLine(input["command"]?.string ?? "a command", max: 70))")
        case "Grep":
            return Step(symbol: "magnifyingglass", text: "Searching for “\(oneLine(input["pattern"]?.string ?? "", max: 50))”")
        case "Glob":
            return Step(symbol: "folder", text: "Finding \(oneLine(input["pattern"]?.string ?? "files", max: 50))")
        case "WebFetch":
            return Step(symbol: "globe", text: "Opening \(host(input["url"]?.string))")
        case "WebSearch":
            return Step(symbol: "globe", text: "Searching the web for “\(oneLine(input["query"]?.string ?? "", max: 50))”")
        case "Task", "Agent":
            let what = input["description"]?.string ?? input["subagent_type"]?.string ?? "a subtask"
            return Step(symbol: "person.2", text: "Delegating \(oneLine(what, max: 60))")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet":
            return Step(symbol: "checklist", text: "Updating the task list")
        case "AskUserQuestion":
            return Step(symbol: "questionmark.bubble", text: "Asking you a question")
        case "ExitPlanMode":
            return Step(symbol: "list.bullet.clipboard", text: "Presenting a plan")
        case "Skill":
            return Step(symbol: "sparkles", text: "Using the \(input["skill"]?.string ?? "a") skill")
        default:
            if let mcp = mcpParts(tool) {
                return Step(symbol: "puzzlepiece.extension", text: "Using \(mcp.server): \(mcp.tool)")
            }
            return Step(symbol: "wrench.and.screwdriver", text: "Using \(tool)")
        }
    }

    // MARK: - Helpers

    public static func fileName(_ path: JSONValue?) -> String {
        guard let path = path?.string, !path.isEmpty else { return "a file" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    public static func oneLine(_ text: String, max: Int) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let multiline = first.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if trimmed.count > max { return String(trimmed.prefix(max - 1)) + "…" }
        return multiline ? trimmed + " …" : trimmed
    }

    public static func host(_ url: String?) -> String {
        guard let url, let host = URL(string: url)?.host else { return url ?? "a page" }
        return host
    }

    /// `mcp__codegraph__codegraph_explore` → ("codegraph", "codegraph explore").
    public static func mcpParts(_ tool: String) -> (server: String, tool: String)? {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        let name = parts[2...].joined(separator: "__").replacingOccurrences(of: "_", with: " ")
        return (parts[1], name)
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Lines added/removed by an Edit, ignoring the unchanged lines it shares at the start and end.
    static func editCounts(old: String?, new: String?) -> (Int?, Int?) {
        guard let old, let new else { return (nil, nil) }
        var a = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false)
        var b = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
        while let x = a.first, let y = b.first, x == y { a.removeFirst(); b.removeFirst() }
        while let x = a.last, let y = b.last, x == y { a.removeLast(); b.removeLast() }
        return (b.count, a.count)
    }
}
