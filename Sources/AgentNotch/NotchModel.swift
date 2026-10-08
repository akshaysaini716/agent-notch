import AgentNotchCore
import AppKit
import SwiftUI

/// Size of the hardware notch (or a stand-in on screens without one).
struct NotchGeometry: Equatable {
    var hasNotch: Bool
    var width: CGFloat
    var height: CGFloat

    static let fallback = NotchGeometry(hasNotch: true, width: 185, height: 32)

    /// The built-in display if it has a notch, otherwise the main display (before the cursor
    /// says otherwise).
    @MainActor static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    @MainActor init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            width = screen.frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
        } else {
            // No notch to sit around: a compact pill in the middle of the menu bar.
            hasNotch = false
            width = 64
            height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        }
    }

    init(hasNotch: Bool, width: CGFloat, height: CGFloat) {
        self.hasNotch = hasNotch
        self.width = width
        self.height = height
    }
}

enum NotchMode: Equatable {
    /// Nothing to show: the shape matches the hardware notch exactly.
    case hidden
    /// Status lights on either side of the notch.
    case collapsed
    /// Session list (on hover) or a request card.
    case expanded
}

@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var board = Board()
    @Published private(set) var hovering = false
    @Published var geometry = NotchGeometry.fallback
    /// Size of the drawn shape, reported by the view; the controller makes only this area clickable.
    @Published var shapeSize: CGSize = .zero
    /// Session shown in the big card. Pinned while the panel is open so it doesn't jump.
    @Published private(set) var focusId: String?
    /// Opened with the hotkey: the panel takes keystrokes until Esc (or a click elsewhere).
    @Published var keyboardOpen = false
    /// The last key for views with their own state (the question card's current choice).
    @Published private(set) var keySignal: KeySignal?
    /// Typed in keyboard mode: narrows the agent list.
    @Published private(set) var filter = ""
    /// Whether the "Older" group (agents quiet for over a day) is unfolded.
    @Published var showOlder = false
    /// Bumped to make the notch bounce when a request has waited too long.
    @Published private(set) var nudges = 0
    @Published var preferences = Preferences.load() {
        didSet { preferences.save() }
    }
    private var lastNudge: [UUID: Date] = [:]

    /// Pins the mode (snapshots, and `GET /debug/open` in debug runs).
    var forcedMode: NotchMode? {
        didSet { objectWillChange.send() }
    }
    /// Held hook requests by card id: each sends the HTTP response body Claude Code is waiting for.
    private var replies: [UUID: (Data) -> Void] = [:]
    private var refresh: DispatchWorkItem?
    private var titleChecks: [String: Date] = [:]
    private let titleQueue = DispatchQueue(label: "agentnotch.titles", qos: .utility)

    var mode: NotchMode {
        if let forcedMode { return forcedMode }
        if !board.attention.isEmpty || hovering || keyboardOpen || visibleNotice != nil { return .expanded }
        return board.isActive(at: Date()) ? .collapsed : .hidden
    }

    // MARK: - Events


    /// The "finished" card to show. Not while you're browsing the open notch: the row already
    /// says Done there, and the card would cover what you're reading.
    var visibleNotice: DoneNotice? {
        hovering || keyboardOpen ? nil : board.notices.first
    }

    // MARK: - Keyboard

    /// The hotkey: open the notch for the keyboard, or close it again.
    func toggleKeyboard() {
        if keyboardOpen {
            closePanel()
        } else {
            if focusId == nil { focusId = NotchModel.mostRelevant(board.orderedSessions)?.id }
            keyboardOpen = true
        }
    }

    /// Handles a key while the panel has keyboard focus. Returns false for keys it ignores.
    func handleKey(_ key: NotchKey) -> Bool {
        if key == .escape {
            // Esc first clears a search, then closes.
            if !filter.isEmpty && board.attention.isEmpty { setFilter("") } else { closePanel() }
            return true
        }
        switch board.attention.first {
        case .permission(let ask):
            switch key {
            case .character("a"): answer(ask.id, .allow)
            case .character("s") where !ask.alwaysAllowRules.isEmpty: answer(ask.id, .allowAlways)
            case .character("d"): answer(ask.id, .deny)
            case .character("t"): answerInTerminal(ask.id, sessionId: ask.sessionId)
            default: return false
            }
            return true
        case .question(let question):
            if key == .character("t") {
                answerInTerminal(question.id, sessionId: question.sessionId)
            } else {
                // The card keeps its own state (current question, ticks); let it act on the key.
                keySignal = KeySignal(key: key)
            }
            return true
        case nil:
            break
        }
        // Typing narrows the list; ⌫ undoes it.
        switch key {
        case .character(let character) where character.isLetter || character.isNumber || " -_.".contains(character):
            setFilter(filter + String(character))
            return true
        case .delete:
            if !filter.isEmpty { setFilter(String(filter.dropLast())) }
            return true
        default:
            break
        }
        let sessions = visibleSessions
        guard !sessions.isEmpty else { return false }
        let index = sessions.firstIndex { $0.id == focusedSession?.id } ?? 0
        switch key {
        case .up: focus(sessions[max(0, index - 1)].id)
        case .down: focus(sessions[min(sessions.count - 1, index + 1)].id)
        case .return: goToTerminal(sessions[index].id)
        default: return false
        }
        return true
    }

    /// Hands a request back to Claude Code's own prompt and takes you to that terminal tab.
    func answerInTerminal(_ id: UUID, sessionId: String) {
        if question(id) != nil { answerQuestion(id, nil) } else { answer(id, .terminal) }
        goToTerminal(sessionId)
    }

    /// Applies a hook event. A permission request comes back so the server can hold its connection.
    func receive(_ event: HookEvent) -> PermissionAsk? {
        let hadAttention = !board.attention.isEmpty
        let noticesBefore = Set(board.notices.map(\.id))
        let ask = board.apply(event, at: Date())
        if !hadAttention && !board.attention.isEmpty { chime("Pop") }
        for notice in board.notices where !noticesBefore.contains(notice.id) { announce(notice) }
        afterEvent(event)
        return ask
    }

    /// Chimes, and takes the card down after a few seconds unless you've opened it.
    private func announce(_ notice: DoneNotice) {
        // Settings decide which finished replies get a card; failures always do unless cards are off.
        let short = (notice.duration ?? 0) < Preferences.longReply
        switch preferences.doneCards {
        case .off:
            board.dismissNotice(notice.id)
            return
        case .long where short && !notice.failed:
            board.dismissNotice(notice.id)
            return
        default:
            break
        }
        chime(notice.failed ? "Basso" : "Glass")
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.cardSeconds) { [weak self] in
            self?.board.dismissNotice(notice.id)
        }
    }

    private func chime(_ sound: String) {
        if preferences.chimes { NSSound(named: sound)?.play() }
    }

    /// Reminds you of requests that have waited too long: a chime and a bounce, every few minutes.
    func nudgeIfWaiting(at now: Date = Date()) {
        lastNudge = lastNudge.filter { id, _ in board.attention.contains { $0.id == id } }
        guard preferences.nudges else { return }
        let due = NudgeSchedule.due(board.attention, lastNudged: lastNudge, at: now, after: Preferences.nudgeAfter)
        for id in due {
            lastNudge[id] = now
            Log.debug("nudge: \(id)")
        }
        if !due.isEmpty {
            chime("Ping")
            nudges += 1
        }
    }

    func dismissNotice(_ id: UUID) {
        board.dismissNotice(id)
    }

    /// From a "finished" card: open the notch on that agent's details, as if you'd hovered in.
    func showDetails(_ notice: DoneNotice) {
        board.dismissNotice(notice.id)
        hovering = true
        focus(notice.sessionId)
    }

    /// Puts an AskUserQuestion on the notch; the server holds its connection until it's answered.
    func receiveQuestion(_ event: HookEvent) -> QuestionAsk? {
        let hadAttention = !board.attention.isEmpty
        let question = board.askQuestion(event, at: Date())
        if !hadAttention && !board.attention.isEmpty { chime("Pop") }
        refreshTitle(for: event)
        return question
    }

    private func afterEvent(_ event: HookEvent) {
        if event.name == HookEventName.stop || event.name == HookEventName.stopFailure {
            // Fold the notch away once the "done" flash is over.
            scheduleRefresh(after: Board.doneFlash + 0.1)
        }
        if event.name == HookEventName.sessionEnd {
            titleChecks[event.sessionId] = nil
        } else {
            refreshTitle(for: event)
        }
        if event.name == HookEventName.stop {
            // Claude's final reply is in the transcript, not the hook payload.
            let id = event.sessionId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.loadDetails(for: id) }
        }
    }

    /// Lists every running Claude Code session (from Claude Code's session files) and reads the
    /// details of ones the notch hasn't seen yet.
    func syncOpenSessions(_ open: [OpenSession]) {
        for id in board.sync(open: open, at: Date()) { loadDetails(for: id) }
        // Which terminal tab each one lives in; fixed for the life of the process.
        for session in board.sessions.values where session.terminal == nil {
            guard let pid = session.pid, let link = Terminals.link(forPid: pid) else { continue }
            board.setTerminal(link, for: session.id)
        }
    }

    /// Your Warp tab names, which you can change at any time: read again every few seconds.
    func refreshTabNames() {
        let panes = board.sessions.values.compactMap { session in session.terminal?.warpPaneId.map { (session.id, $0) } }
        guard !panes.isEmpty else { return }
        titleQueue.async { [weak self] in
            let names = WarpTabs.names(forPanes: panes.map(\.1))
            DispatchQueue.main.async {
                for (session, pane) in panes { self?.board.setTabName(names[pane.lowercased()], for: session) }
            }
        }
    }

    /// Brings an agent's terminal tab to the front and folds the notch away.
    func goToTerminal(_ sessionId: String) {
        guard let link = board.sessions[sessionId]?.terminal else { return }
        Terminals.open(link)
        board.notices.filter { $0.sessionId == sessionId }.forEach { board.dismissNotice($0.id) }
        closePanel()
    }

    /// Closes the open notch (hover, keyboard or pinned) as if the cursor had left.
    func closePanel() {
        hovering = false
        focusId = nil
        keyboardOpen = false
        filter = ""
    }

    /// The rows the list shows, top to bottom: "Older" agents only when unfolded or searching.
    var visibleSessions: [AgentSession] {
        let sections = board.listSections(at: Date(), filter: filter)
        return sections.recent + (showOlder || !filter.isEmpty ? sections.older : [])
    }

    /// Narrows the list (keyboard typing; snapshots).
    func search(_ text: String) { setFilter(text) }

    private func setFilter(_ text: String) {
        filter = text
        if let first = visibleSessions.first { focus(first.id) }
    }

    /// Reads a session's title and recent activity from its transcript, off the main thread.
    func loadDetails(for id: String) {
        let known = board.sessions[id]?.transcriptPath
        titleQueue.async { [weak self] in
            guard let path = known ?? SessionFiles.transcript(for: id) else { return }
            let title = TranscriptTitle.read(path: path)
            let digest = TranscriptDigest.read(path: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.board.setTranscriptPath(path, for: id)
                self.board.setTitle(title, for: id)
                if let digest { self.board.apply(digest, to: id) }
            }
        }
    }

    /// Keeps a hook request open; `send` delivers the response body when the card is answered.
    func hold(_ id: UUID, send: @escaping (Data) -> Void) {
        replies[id] = send
    }

    func answer(_ id: UUID, _ answer: PermissionAnswer) {
        let rules = permission(id)?.alwaysAllowRules ?? []
        replies.removeValue(forKey: id)?(HookReply.permission(answer, rules: rules))
        board.resolve(id, at: Date())
        closeKeyboardIfDone()
    }

    /// Answered from the keyboard and nothing else is waiting: give the keyboard back.
    private func closeKeyboardIfDone() {
        if keyboardOpen && board.attention.isEmpty { closePanel() }
    }

    /// `answers` maps question text to the chosen label(s); nil hands the question to the terminal.
    func answerQuestion(_ id: UUID, _ answers: [String: String]?) {
        Log.debug("question \(id) answered on the notch: \(answers.map { "\($0)" } ?? "to terminal")")
        guard let question = question(id) else { return }
        replies.removeValue(forKey: id)?(HookReply.answers(answers, to: question))
        board.resolve(id, at: Date())
        closeKeyboardIfDone()
    }

    /// Hands every held request back to Claude Code's terminal prompt (the app is quitting).
    func releaseAll() {
        for id in Array(replies.keys) {
            replies.removeValue(forKey: id)?(HookReply.empty)
            board.resolve(id, at: Date())
        }
    }

    private func permission(_ id: UUID) -> PermissionAsk? {
        for case .permission(let ask) in board.attention where ask.id == id { return ask }
        return nil
    }

    private func question(_ id: UUID) -> QuestionAsk? {
        for case .question(let ask) in board.attention where ask.id == id { return ask }
        return nil
    }

    /// Claude Code stopped waiting (Esc, timeout): drop the card without replying.
    func abandon(_ id: UUID) {
        replies[id] = nil
        board.resolve(id, at: Date())
    }

    func prune() {
        board.prune(at: Date())
    }

    func reap(isAlive: (AgentSession) -> Bool) -> [String] {
        board.reap(at: Date(), isAlive: isAlive)
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        // Pin the most relevant session while the panel is open; pick again next time.
        focusId = value ? NotchModel.mostRelevant(board.orderedSessions)?.id : nil
    }

    func focus(_ id: String) {
        if focusId != id { focusId = id }
        // Quiet sessions send no hook events: read what they've been up to now.
        if let session = board.sessions[id], !session.hookSeen || session.status == .ready || session.status == .done {
            loadDetails(for: id)
        }
    }

    var focusedSession: AgentSession? {
        if let focusId, let session = board.sessions[focusId] { return session }
        return NotchModel.mostRelevant(board.orderedSessions)
    }

    /// Needs-you first, then whoever is working (latest activity), then the latest of the rest.
    static func mostRelevant(_ sessions: [AgentSession]) -> AgentSession? {
        let latest = { (list: [AgentSession]) in list.max { $0.lastEventAt < $1.lastEventAt } }
        return sessions.first { $0.status == .needsYou }
            ?? latest(sessions.filter { $0.status == .working })
            ?? latest(sessions)
    }

    /// The single mood the collapsed notch shows: the most urgent across all sessions.
    var overallMood: AgentStatus {
        let statuses = Set(board.sessions.values.map(\.status))
        for status in [AgentStatus.needsYou, .working, .failed, .done] where statuses.contains(status) { return status }
        return .ready
    }

    /// Loads a prepared board (snapshots).
    func load(_ board: Board) {
        self.board = board
    }

    /// Claude writes a session's title shortly after its first prompt and refines it later: look it
    /// up until one exists, then again at turn boundaries. At most every 15s per session, off the
    /// main thread (transcripts run to tens of MB).
    private func refreshTitle(for event: HookEvent) {
        guard let session = board.sessions[event.sessionId], let path = session.transcriptPath else { return }
        let boundary = event.name == HookEventName.userPromptSubmit || event.name == HookEventName.stop
        guard session.title == nil || boundary else { return }
        if let last = titleChecks[session.id], Date().timeIntervalSince(last) < 15 { return }
        titleChecks[session.id] = Date()
        let id = session.id
        titleQueue.async { [weak self] in
            let title = TranscriptTitle.read(path: path)
            DispatchQueue.main.async { self?.board.setTitle(title, for: id) }
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.objectWillChange.send() }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// A key the notch understands.
enum NotchKey: Equatable {
    case up, down, `return`, escape, delete
    case character(Character)
}

/// One key press, delivered to views that keep their own state. Each press is a new value, so
/// pressing the same key twice still registers.
struct KeySignal: Equatable {
    let id = UUID()
    let key: NotchKey
}
