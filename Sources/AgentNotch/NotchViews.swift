import AgentNotchCore
import AppKit
import SwiftUI

/// Fills the panel; the notch shape hangs from the top centre and reports its size so only it
/// takes clicks.
struct NotchRootView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        NotchContent()
            // The controller makes exactly this area clickable, so it must always be current.
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                model.shapeSize = size
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchContent: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        let mode = model.mode
        let radius = mode == .expanded ? Metrics.expandedRadius : Metrics.collapsedRadius
        ZStack(alignment: .top) {
            switch mode {
            case .hidden:
                Color.clear.frame(width: model.geometry.width + 2 * Metrics.flare, height: model.geometry.height)
            case .collapsed:
                CollapsedView()
                    .transition(.opacity)
            case .expanded:
                ExpandedView()
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .background(
            NotchShape(bottomRadius: radius)
                .fill(Palette.notch)
                // Without a hardware notch there is nothing to blend into, so stay invisible when idle.
                .opacity(mode == .hidden && !model.geometry.hasNotch ? 0 : 1)
        )
        .clipShape(NotchShape(bottomRadius: radius))
        .shadow(color: .black.opacity(mode == .expanded ? 0.5 : 0), radius: 20, y: 10)
        .animation(.notch, value: mode)
        .animation(.notch, value: model.board.attention.map(\.id))
        .animation(.notch, value: model.board.sessions.count)
        .animation(.notch, value: model.focusId)
        .animation(.notch, value: model.board.notices.map(\.id))
        // A request that has waited too long: bounce to catch the eye.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: model.nudges) { content, scale in
            content.scaleEffect(scale, anchor: .top)
        } keyframes: { _ in
            SpringKeyframe(1.05, duration: 0.14)
            SpringKeyframe(1.0, duration: 0.3)
            SpringKeyframe(1.035, duration: 0.14)
            SpringKeyframe(1.0, duration: 0.3)
        }
    }
}

// MARK: - Collapsed

/// The buddy on the left of the notch wears the most urgent mood; a light per agent sits on the right.
struct CollapsedView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        let lights = Array(model.board.orderedSessions.filter { $0.status != .ready }.prefix(4))
        HStack(spacing: 0) {
            Buddy(mood: model.overallMood, size: 21, showsBadge: false)
                .frame(width: Metrics.earWidth)
            Color.clear.frame(width: model.geometry.width)
            lightGrid(lights)
                .frame(width: Metrics.earWidth)
        }
        .padding(.horizontal, Metrics.flare)
        .frame(height: model.geometry.height)
    }

    /// One row of lights for up to two agents, a 2×2 grid for more.
    @ViewBuilder
    private func lightGrid(_ sessions: [AgentSession]) -> some View {
        let rows = sessions.count > 2 ? [Array(sessions.prefix(2)), Array(sessions.dropFirst(2))] : [sessions]
        VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row]) { StatusDot(status: $0.status, size: 6) }
                }
            }
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        let sessions = model.board.orderedSessions
        VStack(alignment: .leading, spacing: 10) {
            HeaderStrip(sessions: sessions)
                .frame(height: model.geometry.height - 6)

            if let item = model.board.attention.first {
                AttentionCard(item: item, waiting: model.board.attention.count - 1)
            } else if let notice = model.visibleNotice, let session = model.board.sessions[notice.sessionId] {
                NoticeCard(notice: notice, session: session, more: model.board.notices.count - 1)
            } else if let focus = model.focusedSession {
                if sessions.count > 1 {
                    HStack(alignment: .top, spacing: 10) {
                        AgentList(sessions: sessions, selectedId: focus.id)
                            .frame(width: Metrics.listWidth, height: Metrics.detailHeight)
                        DetailCard(session: focus)
                            .frame(height: Metrics.detailHeight)
                    }
                } else {
                    DetailCard(session: focus)
                        .frame(height: Metrics.detailHeight)
                }
            } else {
                EmptyState()
            }
        }
        .padding(.horizontal, 12 + Metrics.flare)
        .padding(.bottom, 12)
        .frame(width: Metrics.expandedWidth + 2 * Metrics.flare, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            SettingsMenu()
        }
    }
}

/// "This agent finished": its face, how long it took, and the start of Claude's final reply.
struct NoticeCard: View {
    @EnvironmentObject private var model: NotchModel
    let notice: DoneNotice
    let session: AgentSession
    /// Other agents that finished too.
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Buddy(mood: notice.failed ? .failed : .done, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(Fonts.title)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 10) {
                        Text(headline)
                            .font(Fonts.body)
                            .foregroundStyle(notice.failed ? Palette.failed : Palette.done)
                        if session.displayName != session.project {
                            FolderLabel(name: session.project)
                        }
                    }
                }
                Spacer(minLength: 8)
                if more > 0 {
                    Text("\(more) more finished")
                        .font(Fonts.caption)
                        .foregroundStyle(Palette.tertiary)
                }
            }
            if !session.summary.isEmpty {
                SummaryChips(summary: session.summary)
            }
            if let reply = session.lastReply {
                Text(reply)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text.opacity(0.8))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well))
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss") { model.dismissNotice(notice.id) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                if let link = session.terminal {
                    Button("Details") { model.showDetails(notice) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    Button("Open in \(link.appName ?? "terminal")") { model.goToTerminal(session.id) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                } else {
                    Button("Show details") { model.showDetails(notice) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
        .animation(.notch, value: session.lastReply)
        .id(notice.id)
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    private var headline: String {
        if notice.failed { return "Stopped on an API error" }
        return notice.duration.map { "Done in \(Format.elapsed($0))" } ?? "Done"
    }
}

/// The strip beside the hardware notch: how many agents, and how many need something.
struct HeaderStrip: View {
    @EnvironmentObject private var model: NotchModel
    let sessions: [AgentSession]

    var body: some View {
        let working = sessions.filter { $0.status == .working }.count
        let waiting = sessions.filter { $0.status == .needsYou }.count
        HStack(spacing: 12) {
            if !sessions.isEmpty {
                Text(sessions.count == 1 ? "1 agent" : "\(sessions.count) agents")
                    .foregroundStyle(Palette.tertiary)
            }
            if !model.filter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text(model.filter).foregroundStyle(Palette.text)
                }
                .foregroundStyle(Palette.secondary)
            }
            Spacer()
            if model.keyboardOpen && model.board.attention.isEmpty {
                if model.filter.isEmpty {
                    Text("Type to search").foregroundStyle(Palette.tertiary)
                }
                HStack(spacing: 4) { KeyHint("↑"); KeyHint("↓"); Text("choose").foregroundStyle(Palette.tertiary) }
                HStack(spacing: 4) { KeyHint("↩"); Text("open").foregroundStyle(Palette.tertiary) }
                HStack(spacing: 4) { KeyHint("esc"); Text(model.filter.isEmpty ? "close" : "clear").foregroundStyle(Palette.tertiary) }
            } else {
                if waiting > 0 { Text("\(waiting) need\(waiting == 1 ? "s" : "") you").foregroundStyle(Palette.needsYou) }
                if working > 0 { Text("\(working) working").foregroundStyle(Palette.working) }
            }
            Menu {
                SettingsMenu()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Palette.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(Fonts.caption)
        .padding(.horizontal, 6)
    }
}

struct EmptyState: View {
    var body: some View {
        HStack(spacing: 14) {
            Buddy(mood: .ready, size: 40, showsBadge: false)
            VStack(alignment: .leading, spacing: 3) {
                Text("No agents running")
                    .font(Fonts.title)
                    .foregroundStyle(Palette.text)
                Text("Start Claude Code and its sessions appear here.")
                    .font(Fonts.body)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
    }
}

// MARK: - Focus card

/// The selected agent: face, title, status and folder; its prompt and last steps; then what it's
/// touching now, or Claude's last reply once it's idle.
struct DetailCard: View {
    @EnvironmentObject private var model: NotchModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Buddy(mood: session.status, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayName)
                        .font(Fonts.title)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 10) {
                        StatusLine(session: session)
                        if session.displayName != session.project {
                            FolderLabel(name: session.project)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let link = session.terminal {
                    Button { model.goToTerminal(session.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("Open in \(link.appName ?? "terminal")")
                            KeyHint("↩")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            .padding(.top, 2)
            // The panel shows the prompt itself when it has nothing else; don't say it twice.
            if let prompt = session.prompt, !LivePanel.showsPrompt(for: session) {
                Text("“\(prompt)”")
                    .font(Fonts.caption)
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if session.status == .done && !session.summary.isEmpty {
                SummaryChips(summary: session.summary)
            }
            StepChecklist(session: session)
            LivePanel(session: session)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
        .id(session.id)
        .transition(.opacity)
    }
}

/// The folder a session runs in, shown under its title.
struct FolderLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9.5, weight: .medium))
            Text(name)
                .lineLimit(1)
        }
        .font(Fonts.caption)
        .foregroundStyle(Palette.tertiary)
    }
}

/// "Working 2:14", "Done in 0:42", plus the agent's task progress when it keeps a list.
struct StatusLine: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            switch session.status {
            case .working:
                Text("Working").foregroundStyle(Palette.working)
                if let start = session.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.elapsed(context.date.timeIntervalSince(start)))
                    }
                    .foregroundStyle(Palette.secondary)
                }
            case .needsYou:
                Text("Needs you").foregroundStyle(Palette.needsYou)
            case .done:
                Text(doneText).foregroundStyle(Palette.done)
            case .failed:
                Text("Stopped").foregroundStyle(Palette.failed)
            case .ready:
                Text(session.idleSince.map { "Idle for \(Format.ago($0, suffix: false))" } ?? "Ready")
                    .foregroundStyle(Palette.tertiary)
            }
            if let tasks = session.tasks {
                Text("\(tasks.done)/\(tasks.total)").foregroundStyle(Palette.tertiary)
            } else if let subagent = session.subagent {
                Text(subagent).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
        }
        .font(Fonts.caption)
        .monospacedDigit()
    }

    private var doneText: String {
        guard let start = session.turnStartedAt, let end = session.turnEndedAt else { return "Done" }
        return "Done in \(Format.elapsed(end.timeIntervalSince(start)))"
    }
}

struct StepChecklist: View {
    let session: AgentSession

    private let limit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if session.history.isEmpty {
                switch session.status {
                case .working:
                    row(icon: AnyView(Spinner(color: Palette.working, diameter: 10)), text: Step.thinking.text, current: true)
                case .ready:
                    row(icon: AnyView(Image(systemName: "circle.dotted").foregroundStyle(Palette.tertiary)),
                        text: "Waiting for your next prompt", current: false)
                default:
                    EmptyView()
                }
            }
            ForEach(session.history.suffix(limit)) { record in
                row(icon: icon(record.state), text: record.step.text, current: record.state == .running)
            }
        }
    }

    private func row(icon: AnyView, text: String, current: Bool) -> some View {
        HStack(spacing: 8) {
            icon
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 13, height: 13)
            Text(text)
                .font(Fonts.body)
                .foregroundStyle(current ? Palette.text : Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func icon(_ state: StepRecord.State) -> AnyView {
        switch state {
        case .running: return AnyView(Spinner(color: Palette.working, diameter: 10))
        case .done: return AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done))
        case .failed: return AnyView(Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.failed))
        }
    }
}

/// The diff being made, the command being run (and its output), or what is being looked at.
struct LivePanel: View {
    let session: AgentSession

    /// Once an agent is idle, what it last said matters more than its last tool call.
    private var showsReply: Bool { LivePanel.showsReply(for: session) }

    static func showsReply(for session: AgentSession) -> Bool {
        session.lastReply != nil && [.ready, .done, .failed].contains(session.status)
    }

    /// With no reply and no live preview, the panel falls back to the prompt.
    static func showsPrompt(for session: AgentSession) -> Bool {
        !showsReply(for: session) && session.live == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsReply, let reply = session.lastReply {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 1)
                    Text(reply)
                        .font(Fonts.body)
                        .foregroundStyle(Palette.text.opacity(0.8))
                        .lineLimit(7)
                }
            } else {
            switch session.live {
            case .diff(let file, let lines, let hidden, let added, let removed):
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Text(file)
                        .font(Fonts.caption)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    DiffCounts(added: added, removed: removed)
                }
                .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in DiffLineRow(line: line) }
                    if hidden > 0 {
                        Text("\(hidden) more lines")
                            .font(Fonts.caption)
                            .foregroundStyle(Palette.tertiary)
                            .padding(.top, 4)
                    }
                }
            case .command(let command, let output, let finished):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$").foregroundStyle(Palette.working)
                    Text(command).foregroundStyle(Palette.text).lineLimit(2)
                }
                .font(Fonts.code)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(output.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    switch finished {
                    case nil: BlinkingCursor().padding(.top, 2)
                    case .failed?: OutcomeTag(text: "Failed", color: Palette.failed).padding(.top, 4)
                    case .succeeded?: EmptyView()
                    }
                }
                .font(Fonts.code)
                .padding(.top, 6)
            case .text(let symbol, let text):
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.color(for: session.status))
                    Text(text)
                        .font(Fonts.body)
                        .foregroundStyle(Palette.text.opacity(0.85))
                        .lineLimit(3)
                }
            case nil:
                Text(session.prompt.map { "“\($0)”" } ?? "Nothing to show yet")
                    .font(Fonts.body)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(4)
            }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well))
    }
}

struct DiffLineRow: View {
    let line: DiffPreview.Line

    var body: some View {
        let added = line.kind == .added
        HStack(spacing: 7) {
            Text(added ? "+" : "−")
                .foregroundStyle(added ? Palette.done : Palette.failed)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(Palette.text.opacity(added ? 0.92 : 0.5))
                .strikethrough(!added, color: Palette.failed.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(Fonts.code)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill((added ? Palette.done : Palette.failed).opacity(0.12)))
    }
}

struct OutcomeTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
    }
}

struct BlinkingCursor: View {
    var body: some View {
        Rectangle()
            .fill(Palette.text.opacity(0.85))
            .frame(width: 7, height: 13)
            .phaseAnimator([1.0, 0.0]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.5) }
    }
}

// MARK: - Agent list

/// Every open agent, newest first. Click one to see its details.
struct AgentList: View {
    @EnvironmentObject private var model: NotchModel
    let sessions: [AgentSession]
    let selectedId: String

    var body: some View {
        let sections = model.board.listSections(at: Date(), filter: model.filter)
        let searching = !model.filter.isEmpty
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(sections.recent) { session in
                        AgentListRow(session: session, selected: session.id == selectedId)
                            .id(session.id)
                    }
                    if !sections.older.isEmpty {
                        OlderHeader(count: sections.older.count, open: model.showOlder || searching) {
                            model.showOlder.toggle()
                        }
                        if model.showOlder || searching {
                            ForEach(sections.older) { session in
                                AgentListRow(session: session, selected: session.id == selectedId)
                                    .id(session.id)
                            }
                        }
                    }
                    if searching && sections.recent.isEmpty && sections.older.isEmpty {
                        Text("No agents match “\(model.filter)”")
                            .font(Fonts.caption)
                            .foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            }
            .scrollIndicators(.never)
            // Arrow keys move the selection; keep it on screen.
            .onChange(of: selectedId) { _, id in
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
            }
        }
    }
}

/// Folds away agents that have been quiet for over a day.
struct OlderHeader: View {
    let count: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("Quiet for over a day")
                Text("\(count)").monospacedDigit()
                Spacer()
            }
            .font(Fonts.caption)
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: open)
    }
}

struct AgentListRow: View {
    @EnvironmentObject private var model: NotchModel
    let session: AgentSession
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Buddy(mood: session.status, size: 22, showsBadge: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                StatusLabel(session: session, waitingSince: model.board.attention(for: session.id).first?.receivedAt)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Palette.card : Color.white.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.focus(session.id) }
        .onHover { hovering = $0 }
    }
}

struct StatusLabel: View {
    let session: AgentSession
    /// When its request reached the notch, for "Needs you 4m".
    var waitingSince: Date? = nil

    var body: some View {
        Group {
            switch session.status {
            case .working:
                if let start = session.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Working \(Format.elapsed(context.date.timeIntervalSince(start)))")
                    }
                    .foregroundStyle(Palette.working)
                } else {
                    Text("Working").foregroundStyle(Palette.working)
                }
            case .needsYou:
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(waitingText(at: context.date))
                }
                .foregroundStyle(Palette.needsYou)
            case .done:
                Text(session.turnEndedAt.map { "Done \(Format.ago($0))" } ?? "Done").foregroundStyle(Palette.done)
            case .failed: Text("Stopped").foregroundStyle(Palette.failed)
            case .ready:
                Text(session.idleSince.map { "Idle \(Format.ago($0))" } ?? "Ready").foregroundStyle(Palette.tertiary)
            }
        }
        .font(Fonts.caption)
        .monospacedDigit()
    }
}

extension StatusLabel {
    func waitingText(at now: Date) -> String {
        guard let since = waitingSince, now.timeIntervalSince(since) >= 60 else { return "Needs you" }
        return "Needs you \(Format.ago(since, suffix: false, now: now))"
    }
}

/// What a finished turn did: files changed, and how its last test, build or lint run went.
struct SummaryChips: View {
    let summary: TurnSummary

    var body: some View {
        HStack(spacing: 8) {
            if !summary.files.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                    Text(summary.files.count == 1 ? "1 file" : "\(summary.files.count) files")
                        .foregroundStyle(Palette.text.opacity(0.85))
                    DiffCounts(added: summary.added, removed: summary.removed)
                }
                .chip()
            }
            if let check = summary.check {
                HStack(spacing: 5) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? Palette.done : Palette.failed)
                    Text(check.headline)
                        .foregroundStyle(check.passed ? Palette.done : Palette.failed)
                    if let detail = check.detail {
                        Text(detail).foregroundStyle(Palette.tertiary).lineLimit(1)
                    }
                }
                .chip()
            }
            Spacer(minLength: 0)
        }
        .font(Fonts.caption)
        .foregroundStyle(Palette.secondary)
    }
}

private extension View {
    func chip() -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Palette.well))
    }
}

/// The settings, shown from the gear in the open notch and on right-click.
struct SettingsMenu: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        Toggle("Chimes", isOn: $model.preferences.chimes)
        Picker("Show a card when an agent finishes", selection: $model.preferences.doneCards) {
            ForEach(Preferences.DoneCards.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Keep finished cards up for", selection: $model.preferences.cardSeconds) {
            Text("5 seconds").tag(5.0)
            Text("8 seconds").tag(8.0)
            Text("15 seconds").tag(15.0)
        }
        Toggle("Remind me when an agent waits 3+ minutes", isOn: $model.preferences.nudges)
        Divider()
        Toggle("Start at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
        Divider()
        Button("Quit AgentNotch") { NSApp.terminate(nil) }
    }
}

struct DiffCounts: View {
    let added: Int?
    let removed: Int?

    var body: some View {
        HStack(spacing: 4) {
            if let added, added > 0 { Text("+\(added)").foregroundStyle(Palette.done) }
            if let removed, removed > 0 { Text("−\(removed)").foregroundStyle(Palette.failed) }
        }
        .font(Fonts.caption)
        .monospacedDigit()
    }
}
