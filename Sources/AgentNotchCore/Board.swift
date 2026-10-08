import Foundation

public enum AgentStatus: Equatable, Sendable {
    /// Session is open but no prompt has been sent yet.
    case ready
    case working
    /// Blocked on the person: a permission prompt or a question.
    case needsYou
    case done
    /// The turn ended on an API error.
    case failed
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public static let historyLimit = 5

    public let id: String
    /// Folder name of `cwd`.
    public var project: String
    /// Claude's title for the session (what `/resume` lists), read from the transcript.
    public var title: String?
    /// A name someone gave the session (Claude Code's session file), which beats the title.
    public var customName: String?
    /// Your name for the terminal tab it runs in (Warp), which beats everything: it's the name you
    /// see when you switch to it.
    public var tabName: String?
    /// How to bring its terminal tab to the front.
    public var terminal: TerminalLink?
    /// The Claude Code process, when the session file lists it. Such sessions live exactly as long
    /// as the process does.
    public var pid: Int32?
    /// Whether hook events have arrived. Until then, status comes from the session file.
    public var hookSeen = false
    /// When an idle session (per the session file) went quiet.
    public var idleSince: Date?
    /// Claude's last text reply, from the transcript.
    public var lastReply: String?
    /// Files changed and test/build outcome in the current (or just finished) turn.
    public var summary = TurnSummary()
    public var transcriptPath: String?
    /// Directory the session was first seen in; matched against running `claude` processes.
    public var cwd: String?
    public var status: AgentStatus
    public var step: Step?
    /// The last few tool calls, oldest first.
    public var history: [StepRecord] = []
    public var live: LivePreview?
    public var tasks: TaskProgress?
    /// Tool calls made in the current turn.
    public var steps: Int
    /// First line of the latest prompt, so a finished session still says what it was about.
    public var prompt: String?
    /// Subagent currently doing the work, e.g. "Explore".
    public var subagent: String?
    /// Why the session needs you when the request isn't on the notch (e.g. a terminal prompt).
    public var notice: String?
    public var firstSeenAt: Date
    public var lastEventAt: Date
    public var turnStartedAt: Date?
    public var turnEndedAt: Date?

    /// What the notch calls the agent: your tab name, a name you gave the session, its title, or
    /// the folder.
    public var displayName: String { tabName ?? customName ?? title ?? project }

    public init(id: String, cwd: String?, at now: Date) {
        self.id = id
        self.cwd = cwd
        self.project = Board.projectName(cwd)
        self.status = .ready
        self.steps = 0
        self.firstSeenAt = now
        self.lastEventAt = now
    }
}

/// A permission request that Claude Code is blocked on. The HTTP request that delivered it is
/// held open by the app until the person answers.
public struct PermissionAsk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionId: String
    public let toolName: String
    public let input: JSONValue?
    /// Everything Claude Code proposes: allow rules, but also directory grants and mode switches.
    public let suggestions: [JSONValue]
    public let receivedAt: Date

    /// What "Always allow" sends back as `updatedPermissions`: only the allow rules for this kind of
    /// call. Mode changes (e.g. `setMode: acceptEdits`) are left out, or one click would quietly
    /// switch the whole session to accepting every edit.
    public var alwaysAllowRules: [JSONValue] {
        suggestions.filter { $0["type"]?.string == "addRules" && $0["behavior"]?.string == "allow" }
    }

    /// The rules in Claude Code's own notation, e.g. `Bash(npm test *)`.
    public var alwaysAllowSummary: String? {
        let rules = alwaysAllowRules.flatMap { $0["rules"]?.array ?? [] }.compactMap { rule -> String? in
            guard let tool = rule["toolName"]?.string else { return nil }
            return rule["ruleContent"]?.string.map { "\(tool)(\($0))" } ?? tool
        }
        return rules.isEmpty ? nil : rules.joined(separator: ", ")
    }
}

/// An `AskUserQuestion` call, held (its PreToolUse hook request kept open) until it is answered
/// on the notch or handed back to the terminal.
public struct QuestionAsk: Identifiable, Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var label: String
        public var description: String?
    }

    public struct Question: Equatable, Sendable {
        public var header: String?
        public var text: String
        public var options: [Option]
        public var multiSelect: Bool
    }

    public let id: UUID
    public let sessionId: String
    public let questions: [Question]
    /// The tool input as Claude sent it; the answer echoes it back with `answers` added.
    public let input: JSONValue
    public let receivedAt: Date

    init?(event: HookEvent, at now: Date) {
        guard let input = event.toolInput else { return nil }
        let questions = (input["questions"]?.array ?? []).compactMap { item -> Question? in
            guard let text = item["question"]?.string else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { option -> Option? in
                guard let label = option["label"]?.string else { return nil }
                let description = option["description"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                return Option(label: label, description: description)
            }
            guard !options.isEmpty else { return nil }
            return Question(header: item["header"]?.string, text: text, options: options,
                            multiSelect: item["multiSelect"]?.bool ?? false)
        }
        guard !questions.isEmpty else { return nil }
        self.id = UUID()
        self.sessionId = event.sessionId
        self.questions = questions
        self.input = input
        self.receivedAt = now
    }
}

/// "This agent finished": pops the notch open for a moment so you know without watching it.
public struct DoneNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionId: String
    /// The turn ended on an API error rather than finishing.
    public let failed: Bool
    /// How long the turn took, when the notch saw it start.
    public let duration: TimeInterval?
    public let at: Date
}

public enum Attention: Identifiable, Equatable, Sendable {
    case permission(PermissionAsk)
    case question(QuestionAsk)

    public var id: UUID {
        switch self {
        case .permission(let ask): return ask.id
        case .question(let ask): return ask.id
        }
    }

    public var sessionId: String {
        switch self {
        case .permission(let ask): return ask.sessionId
        case .question(let ask): return ask.sessionId
        }
    }

    /// When the agent started waiting on you.
    public var receivedAt: Date {
        switch self {
        case .permission(let ask): return ask.receivedAt
        case .question(let ask): return ask.receivedAt
        }
    }
}

/// Everything the notch shows, rebuilt from the hook event stream. A value type so it can be
/// tested without the app.
public struct Board: Equatable, Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    /// Requests waiting on the person, oldest first.
    public private(set) var attention: [Attention] = []
    /// Agents that just finished, oldest first.
    public private(set) var notices: [DoneNotice] = []

    /// How long a finished session keeps the notch open before it folds away.
    public static let doneFlash: TimeInterval = 6
    /// Sessions with no events for this long are dropped (Claude Code was killed without SessionEnd).
    public static let staleAfter: TimeInterval = 2 * 60 * 60

    public init() {}

    /// Newest session first, in an order that doesn't change while you read the list.
    public var orderedSessions: [AgentSession] {
        sessions.values.sorted { ($0.firstSeenAt, $0.id) > ($1.firstSeenAt, $1.id) }
    }

    /// Whether the collapsed notch should show anything at all.
    public func isActive(at now: Date) -> Bool {
        sessions.values.contains { session in
            switch session.status {
            case .working, .needsYou: return true
            case .done, .failed: return session.turnEndedAt.map { now.timeIntervalSince($0) < Board.doneFlash } ?? false
            case .ready: return false
            }
        }
    }

    public func attention(for sessionId: String) -> [Attention] {
        attention.filter { $0.sessionId == sessionId }
    }

    /// Applies one hook event. Returns the permission ask when the event is a `PermissionRequest`,
    /// so the caller can hold the HTTP request open until it is answered.
    @discardableResult
    public mutating func apply(_ event: HookEvent, at now: Date) -> PermissionAsk? {
        if event.name == HookEventName.sessionEnd {
            sessions[event.sessionId] = nil
            attention.removeAll { $0.sessionId == event.sessionId }
            notices.removeAll { $0.sessionId == event.sessionId }
            return nil
        }

        var session = sessions[event.sessionId]
            ?? AgentSession(id: event.sessionId, cwd: event.cwd, at: now)
        session.lastEventAt = now
        session.hookSeen = true
        session.idleSince = nil
        if let path = event.transcriptPath { session.transcriptPath = path }
        var ask: PermissionAsk?

        switch event.name {
        case HookEventName.sessionStart:
            if session.status != .working && session.status != .needsYou { session.status = .ready }

        case HookEventName.userPromptSubmit:
            session.status = .working
            session.step = .thinking
            session.steps = 0
            session.prompt = event.prompt.map { Step.oneLine($0, max: 80) }
            session.subagent = nil
            session.notice = nil
            session.turnStartedAt = now
            session.turnEndedAt = nil
            session.history = []
            session.live = nil
            session.tasks = nil
            session.lastReply = nil
            session.summary = TurnSummary()
            attention.removeAll { $0.sessionId == event.sessionId }
            notices.removeAll { $0.sessionId == event.sessionId }

        case HookEventName.preToolUse:
            guard let tool = event.toolName else { break }
            let step = Step.describe(tool: tool, input: event.toolInput)
            session.step = step
            session.steps += 1
            session.history.append(StepRecord(id: event.toolUseId ?? UUID().uuidString, tool: tool, step: step, state: .running))
            session.history = Array(session.history.suffix(AgentSession.historyLimit))
            if let live = LivePreview.starting(tool: tool, input: event.toolInput) { session.live = live }
            if tool == "TodoWrite", let tasks = TaskProgress(todos: event.toolInput?["todos"]) { session.tasks = tasks }
            session.subagent = event.agentType
            beginTurnIfNeeded(&session, at: now)
            // AskUserQuestion's card comes from its own held hook (`askQuestion`), not this event.
            if attention(for: session.id).isEmpty {
                session.status = .working
            }

        case HookEventName.postToolUse, HookEventName.postToolUseFailure:
            let failed = event.name == HookEventName.postToolUseFailure
            if let index = Board.runningStep(in: session.history, for: event) {
                session.history[index].state = failed ? .failed : .done
            }
            if event.toolName == "Bash", let live = session.live {
                session.live = live.finishing(response: event.toolResponse, failed: failed, error: event.error)
            }
            // Subagents' work is part of the turn too.
            session.summary.record(tool: event.toolName, input: event.toolInput,
                                   output: LivePreview.output(response: event.toolResponse, error: event.error),
                                   failed: failed)
            if event.toolName == "AskUserQuestion" {
                attention.removeAll {
                    if case .question = $0 { return $0.sessionId == event.sessionId }
                    return false
                }
            }
            if attention(for: session.id).isEmpty {
                session.status = .working
                session.notice = nil
            }

        case HookEventName.permissionRequest:
            guard let tool = event.toolName else { break }
            let permission = PermissionAsk(id: UUID(), sessionId: session.id, toolName: tool, input: event.toolInput,
                                           suggestions: event.permissionSuggestions, receivedAt: now)
            attention.append(.permission(permission))
            session.step = Step.describe(tool: tool, input: event.toolInput)
            session.status = .needsYou
            beginTurnIfNeeded(&session, at: now)
            ask = permission

        case HookEventName.notification:
            // A prompt is showing in the terminal that the notch isn't holding (e.g. the person
            // chose "Answer in terminal", or the hook timed out).
            let blocking: Set<String> = ["permission_prompt", "elicitation_dialog"]
            if let type = event.notificationType, blocking.contains(type), attention(for: session.id).isEmpty {
                session.status = .needsYou
                session.notice = event.message
            }

        case HookEventName.stop:
            session.status = .done
            session.turnEndedAt = now
            Board.settle(&session.history, as: .done)
            notify(session, failed: false, at: now)
            session.subagent = nil
            session.notice = nil
            attention.removeAll { $0.sessionId == event.sessionId }

        case HookEventName.stopFailure:
            session.status = .failed
            session.turnEndedAt = now
            session.subagent = nil
            session.notice = "Stopped on an API error"
            Board.settle(&session.history, as: .failed)
            notify(session, failed: true, at: now)
            attention.removeAll { $0.sessionId == event.sessionId }

        case HookEventName.subagentStart:
            session.subagent = event.agentType

        case HookEventName.subagentStop:
            session.subagent = nil

        default:
            break
        }

        sessions[session.id] = session
        return ask
    }

    public mutating func dismissNotice(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    /// Queues a "finished" notice for every turn that ends, however short. One per session: a
    /// newer one replaces it.
    private mutating func notify(_ session: AgentSession, failed: Bool, at now: Date) {
        let duration = session.turnStartedAt.map { now.timeIntervalSince($0) }
        notices.removeAll { $0.sessionId == session.id }
        notices.append(DoneNotice(id: UUID(), sessionId: session.id, failed: failed, duration: duration, at: now))
    }

    /// Puts an `AskUserQuestion` on the notch. The caller holds the hook request until it is answered.
    public mutating func askQuestion(_ event: HookEvent, at now: Date) -> QuestionAsk? {
        guard event.toolName == "AskUserQuestion", let question = QuestionAsk(event: event, at: now) else { return nil }
        var session = sessions[event.sessionId] ?? AgentSession(id: event.sessionId, cwd: event.cwd, at: now)
        if let path = event.transcriptPath { session.transcriptPath = path }
        session.lastEventAt = now
        session.status = .needsYou
        session.step = Step.describe(tool: "AskUserQuestion", input: event.toolInput)
        sessions[session.id] = session
        attention.append(.question(question))
        return question
    }

    public mutating func setTerminal(_ link: TerminalLink?, for sessionId: String) {
        guard sessions[sessionId] != nil, sessions[sessionId]?.terminal != link else { return }
        sessions[sessionId]?.terminal = link
    }

    public mutating func setTabName(_ name: String?, for sessionId: String) {
        let name = name?.trimmingCharacters(in: .whitespaces)
        let value = (name?.isEmpty ?? true) ? nil : name
        guard sessions[sessionId] != nil, sessions[sessionId]?.tabName != value else { return }
        sessions[sessionId]?.tabName = value
    }

    public mutating func setTranscriptPath(_ path: String, for sessionId: String) {
        guard sessions[sessionId]?.transcriptPath != path else { return }
        sessions[sessionId]?.transcriptPath = path
    }

    public mutating func setTitle(_ title: String?, for sessionId: String) {
        guard let title, sessions[sessionId]?.title != title else { return }
        sessions[sessionId]?.title = title
    }

    /// Removes an answered (or abandoned) request. The session goes back to work once nothing
    /// else is waiting on it.
    public mutating func resolve(_ id: UUID, at now: Date) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        let sessionId = attention.remove(at: index).sessionId
        guard var session = sessions[sessionId], attention(for: sessionId).isEmpty else { return }
        if session.status == .needsYou { session.status = .working }
        session.notice = nil
        session.lastEventAt = now
        sessions[sessionId] = session
    }

    /// Brings the board in line with the sessions Claude Code lists as running: adds the ones it
    /// hasn't seen (returned, so their transcripts can be read), and drops ones whose process exited.
    @discardableResult
    public mutating func sync(open: [OpenSession], at now: Date) -> [String] {
        var discovered: [String] = []
        for entry in open {
            var session: AgentSession
            if let existing = sessions[entry.sessionId] {
                session = existing
            } else {
                session = AgentSession(id: entry.sessionId, cwd: entry.cwd, at: now)
                discovered.append(entry.sessionId)
            }
            session.pid = entry.pid
            // List order follows when the session started, not when the notch noticed it.
            session.firstSeenAt = min(session.firstSeenAt, entry.startedAt)
            session.customName = entry.nameIsCustom ? entry.name : nil
            if !session.hookSeen {
                session.status = entry.busy ? .working : .ready
                session.turnStartedAt = entry.busy ? entry.statusSince : session.turnStartedAt
                session.idleSince = entry.busy ? nil : entry.statusSince
            }
            sessions[entry.sessionId] = session
        }
        let running = Set(open.map(\.sessionId))
        for (id, session) in sessions where session.pid != nil && !running.contains(id) && attention(for: id).isEmpty {
            sessions[id] = nil
        }
        return discovered
    }

    /// Fills in what a session has been doing from its transcript. Hook events know better, so
    /// this never overwrites them, except Claude's last reply, which only the transcript has.
    public mutating func apply(_ digest: TranscriptDigest, to sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        if session.history.isEmpty { session.history = digest.steps }
        if session.live == nil { session.live = digest.live }
        if session.prompt == nil { session.prompt = digest.prompt }
        if let reply = digest.lastReply { session.lastReply = reply }
        // An idle session isn't running anything: calls left open were interrupted.
        if session.status != .working && session.status != .needsYou {
            Board.settle(&session.history, as: .done)
        }
        sessions[sessionId] = session
    }

    /// Drops sessions whose Claude Code process is gone (killed without a SessionEnd).
    /// Sessions that posted an event within `grace` are always kept, as are ones with a request
    /// still on the notch.
    @discardableResult
    public mutating func reap(at now: Date, grace: TimeInterval = 90, isAlive: (AgentSession) -> Bool) -> [String] {
        let dead = sessions.values.filter { session in
            // Sessions with a pid are tracked through Claude Code's session files instead.
            session.pid == nil
                && now.timeIntervalSince(session.lastEventAt) > grace
                && attention(for: session.id).isEmpty
                && !isAlive(session)
        }.map(\.id)
        for id in dead { sessions[id] = nil }
        return dead
    }

    public mutating func prune(at now: Date) {
        let stale = sessions.values.filter { $0.pid == nil && now.timeIntervalSince($0.lastEventAt) > Board.staleAfter }.map(\.id)
        for id in stale where attention(for: id).isEmpty {
            sessions[id] = nil
        }
    }

    public static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// The running step a PostToolUse closes: matched by `tool_use_id`, else the oldest running
    /// call of the same tool.
    static func runningStep(in history: [StepRecord], for event: HookEvent) -> Int? {
        if let id = event.toolUseId, let index = history.lastIndex(where: { $0.id == id && $0.state == .running }) {
            return index
        }
        return history.firstIndex { $0.state == .running && $0.tool == event.toolName }
    }

    /// A turn that ends leaves nothing spinning.
    static func settle(_ history: inout [StepRecord], as state: StepRecord.State) {
        for index in history.indices where history[index].state == .running {
            history[index].state = state
        }
    }

    /// Events can arrive for a session the app never saw a prompt for (app started mid-turn).
    private func beginTurnIfNeeded(_ session: inout AgentSession, at now: Date) {
        if session.turnStartedAt == nil || session.turnEndedAt != nil {
            session.turnStartedAt = now
            session.turnEndedAt = nil
        }
    }
}

// MARK: - The agent list

extension AgentSession {
    /// When the session last did anything.
    public var lastActive: Date { idleSince ?? turnEndedAt ?? lastEventAt }

    /// Quiet for over a day: folded into "Older" in the list.
    public func isOlder(at now: Date) -> Bool {
        [.ready, .done, .failed].contains(status) && now.timeIntervalSince(lastActive) > Board.olderAfter
    }

    /// Case-insensitive match on any of its names or its folder.
    public func matches(_ filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return [displayName, title, tabName, customName, project].compactMap { $0 }
            .contains { $0.lowercased().contains(needle) }
    }
}

extension Board {
    public static let olderAfter: TimeInterval = 24 * 60 * 60

    /// The list as shown: recent agents, then ones quiet for over a day. A filter searches both.
    public func listSections(at now: Date, filter: String = "") -> (recent: [AgentSession], older: [AgentSession]) {
        let matching = orderedSessions.filter { $0.matches(filter) }
        return (matching.filter { !$0.isOlder(at: now) }, matching.filter { $0.isOlder(at: now) })
    }
}

/// When to remind you about requests that are still waiting.
public enum NudgeSchedule {
    /// Requests due a reminder: waiting at least `after` since they arrived, or since their last
    /// reminder.
    public static func due(_ attention: [Attention], lastNudged: [UUID: Date], at now: Date, after: TimeInterval) -> [UUID] {
        attention.filter { now.timeIntervalSince(lastNudged[$0.id] ?? $0.receivedAt) >= after }.map(\.id)
    }
}
