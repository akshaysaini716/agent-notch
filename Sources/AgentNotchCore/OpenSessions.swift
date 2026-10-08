import Foundation

/// A running Claude Code session, from the file Claude Code keeps per process at
/// `~/.claude/sessions/<pid>.json` (pid, session id, cwd, busy/idle). This is how the notch
/// lists every open agent, including ones that haven't sent a hook event since it started.
public struct OpenSession: Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String?
    /// Claude Code's name for the session, e.g. `payments-api-6b`.
    public var name: String?
    /// True when someone set the name; derived names are less useful than the session title.
    public var nameIsCustom: Bool
    public var busy: Bool
    public var startedAt: Date
    /// When `busy` last changed: how long it has been working, or idle.
    public var statusSince: Date

    public init(pid: Int32, sessionId: String, cwd: String?, name: String? = nil, nameIsCustom: Bool = false,
                busy: Bool, startedAt: Date, statusSince: Date) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.nameIsCustom = nameIsCustom
        self.busy = busy
        self.startedAt = startedAt
        self.statusSince = statusSince
    }

    public init?(data: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let pid)? = json["pid"], let sessionId = json["sessionId"]?.string else { return nil }
        func date(_ key: String) -> Date? {
            guard case .number(let ms)? = json[key] else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        let startedAt = date("startedAt") ?? Date()
        self.init(pid: Int32(pid), sessionId: sessionId, cwd: json["cwd"]?.string,
                  name: json["name"]?.string,
                  nameIsCustom: (json["nameSource"]?.string).map { $0 != "derived" } ?? false,
                  busy: json["status"]?.string == "busy",
                  startedAt: startedAt,
                  statusSince: date("statusUpdatedAt") ?? date("updatedAt") ?? startedAt)
    }
}

/// What a session has been doing, read from the end of its transcript: for agents that were
/// already open before the notch started, or quiet since.
public struct TranscriptDigest: Equatable, Sendable {
    public var prompt: String?
    public var steps: [StepRecord] = []
    public var live: LivePreview?
    /// Claude's last text reply, trimmed.
    public var lastReply: String?

    public static let tailBytes = 512 * 1024
    public static let replyLimit = 600

    public init(prompt: String? = nil, steps: [StepRecord] = [], live: LivePreview? = nil, lastReply: String? = nil) {
        self.prompt = prompt
        self.steps = steps
        self.live = live
        self.lastReply = lastReply
    }

    /// Reads the last `tailBytes` of a transcript.
    public static func read(path: String, tailBytes: Int = tailBytes) -> TranscriptDigest? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        // Drop the line cut in half at the start of the tail.
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[(newline + 1)...] }
        return parse(data)
    }

    /// Builds the digest from JSONL transcript lines, oldest first.
    public static func parse(_ data: Data) -> TranscriptDigest {
        var digest = TranscriptDigest()
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(JSONValue.self, from: Data(line)) else { continue }
            // Subagent chatter and injected (meta) messages aren't the session's own story.
            if entry["isSidechain"]?.bool == true || entry["isMeta"]?.bool == true { continue }
            switch entry["type"]?.string {
            case "last-prompt":
                if let prompt = entry["lastPrompt"]?.string { digest.setPrompt(prompt) }
            case "user":
                if let prompt = entry["message"]?["content"]?.string {
                    digest.setPrompt(prompt)
                } else {
                    for block in entry["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                        digest.finish(block, result: entry["toolUseResult"])
                    }
                }
            case "assistant":
                for block in entry["message"]?["content"]?.array ?? [] {
                    switch block["type"]?.string {
                    case "tool_use": digest.start(block)
                    case "text": digest.setReply(block["text"]?.string)
                    default: break
                    }
                }
            default:
                break
            }
        }
        return digest
    }

    private mutating func setPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash-command and system wrappers (`<command-name>…`) aren't something you typed.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return }
        prompt = Step.oneLine(trimmed, max: 80)
        // A new prompt starts a new turn.
        steps = []
        live = nil
        lastReply = nil
    }

    private mutating func setReply(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        lastReply = text.count > Self.replyLimit ? String(text.prefix(Self.replyLimit - 1)) + "…" : text
    }

    private mutating func start(_ block: JSONValue) {
        guard let tool = block["name"]?.string else { return }
        let input = block["input"]
        steps.append(StepRecord(id: block["id"]?.string ?? UUID().uuidString, tool: tool,
                                step: Step.describe(tool: tool, input: input), state: .running))
        steps = Array(steps.suffix(AgentSession.historyLimit))
        if let preview = LivePreview.starting(tool: tool, input: input) { live = preview }
    }

    private mutating func finish(_ block: JSONValue, result: JSONValue?) {
        let failed = block["is_error"]?.bool ?? false
        guard let id = block["tool_use_id"]?.string, let index = steps.lastIndex(where: { $0.id == id }) else { return }
        steps[index].state = failed ? .failed : .done
        // Only the latest call owns the preview.
        if steps[index].tool == "Bash", index == steps.count - 1, let preview = live {
            live = preview.finishing(response: result, failed: failed)
        }
    }
}
