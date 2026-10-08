import AgentNotchCore
import SwiftUI

struct AttentionCard: View {
    @EnvironmentObject private var model: NotchModel
    let item: Attention
    /// Other requests queued behind this one.
    let waiting: Int

    var body: some View {
        let session = model.board.sessions[item.sessionId]
        let agent = AgentLabel(name: session?.displayName ?? "Claude Code",
                               folder: session?.title == nil ? nil : session?.project)
        Group {
            switch item {
            case .permission(let ask):
                PermissionCard(ask: ask, agent: agent, waiting: waiting)
            case .question(let ask):
                QuestionCard(ask: ask, agent: agent, waiting: waiting)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
        .id(item.id)
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
}

/// Who is asking: the session's title, and its folder once it has a title.
struct AgentLabel {
    var name: String
    var folder: String?
}

private struct CardHeader: View {
    let agent: AgentLabel
    let action: String
    let waiting: Int
    /// When the request arrived, for "Waiting 4m".
    var since: Date? = nil

    var body: some View {
        HStack(spacing: 12) {
            Buddy(mood: .needsYou, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(Fonts.title)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 10) {
                    Text(action)
                        .font(Fonts.body)
                        .foregroundStyle(Palette.needsYou)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let folder = agent.folder {
                        FolderLabel(name: folder).fixedSize()
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let since {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if context.date.timeIntervalSince(since) >= 60 {
                            Text("Waiting \(Format.ago(since, suffix: false, now: context.date))")
                                .foregroundStyle(Palette.needsYou.opacity(0.8))
                        }
                    }
                }
                if waiting > 0 {
                    Text("\(waiting) more waiting").foregroundStyle(Palette.tertiary)
                }
            }
            .font(Fonts.caption)
        }
    }
}

// MARK: - Permission

struct PermissionCard: View {
    @EnvironmentObject private var model: NotchModel
    let ask: PermissionAsk
    let agent: AgentLabel
    let waiting: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(agent: agent, action: "Wants to \(PermissionCopy.action(ask))", waiting: waiting, since: ask.receivedAt)
            PermissionPreview(ask: ask)
            if let rule = ask.alwaysAllowSummary {
                Text("Always allow saves \(rule) to this project's local settings.")
                    .font(Fonts.caption)
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Button { model.answerInTerminal(ask.id, sessionId: ask.sessionId) } label: {
                    HintedLabel(title: "Answer in terminal", key: "T")
                }
                .buttonStyle(.plain)
                .font(Fonts.caption)
                .foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Button { model.answer(ask.id, .deny) } label: { HintedLabel(title: "Deny", key: "D") }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                if !ask.alwaysAllowRules.isEmpty {
                    Button { model.answer(ask.id, .allowAlways) } label: { HintedLabel(title: "Always allow", key: "S") }
                        .buttonStyle(PillButtonStyle(kind: .outline))
                }
                Button { model.answer(ask.id, .allow) } label: { HintedLabel(title: "Allow", key: "A") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
    }
}

enum PermissionCopy {
    static func action(_ ask: PermissionAsk) -> String {
        let input = ask.input
        switch ask.toolName {
        case "Bash": return "run a command"
        case "Edit", "MultiEdit": return "edit \(Step.fileName(input?["file_path"]))"
        case "NotebookEdit": return "edit \(Step.fileName(input?["notebook_path"]))"
        case "Write": return "write \(Step.fileName(input?["file_path"]))"
        case "Read": return "read \(Step.fileName(input?["file_path"]))"
        case "WebFetch": return "open \(Step.host(input?["url"]?.string))"
        case "WebSearch": return "search the web"
        default:
            if let mcp = Step.mcpParts(ask.toolName) { return "use \(mcp.server)" }
            return "use \(ask.toolName)"
        }
    }
}

struct PermissionPreview: View {
    let ask: PermissionAsk

    var body: some View {
        let input = ask.input
        switch ask.toolName {
        case "Bash":
            VStack(alignment: .leading, spacing: 8) {
                if let description = input?["description"]?.string {
                    Text(description)
                        .font(Fonts.body)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(2)
                }
                CodeWell(text: input?["command"]?.string ?? "", lineLimit: 6)
            }
        case "Edit", "MultiEdit":
            DiffWell(old: input?["old_string"]?.string ?? "", new: input?["new_string"]?.string ?? "")
        case "Write":
            DiffWell(old: "", new: input?["content"]?.string ?? "")
        case "WebFetch":
            CodeWell(text: input?["url"]?.string ?? "", lineLimit: 2)
        case "WebSearch":
            CodeWell(text: input?["query"]?.string ?? "", lineLimit: 2)
        default:
            CodeWell(text: fields(input), lineLimit: 6)
        }
    }

    /// `key: value` lines for tools we don't special-case (MCP tools, mostly).
    private func fields(_ input: JSONValue?) -> String {
        if let mcp = Step.mcpParts(ask.toolName), input?.object?.isEmpty ?? true { return mcp.tool }
        guard let object = input?.object, !object.isEmpty else { return ask.toolName }
        return object.keys.sorted().prefix(6)
            .map { "\($0): \(Step.oneLine(object[$0]?.summary ?? "", max: 80))" }
            .joined(separator: "\n")
    }
}

struct CodeWell: View {
    let text: String
    let lineLimit: Int

    var body: some View {
        Text(text)
            .font(Fonts.code)
            .foregroundStyle(Palette.text.opacity(0.92))
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well))
    }
}

struct DiffWell: View {
    let old: String
    let new: String

    var body: some View {
        let preview = DiffPreview.lines(old: old, new: new, limit: 8)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.kind == .added ? "+" : "−")
                        .foregroundStyle(line.kind == .added ? Palette.done : Palette.failed)
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(Palette.text.opacity(line.kind == .added ? 0.92 : 0.55))
                        .lineLimit(1)
                }
            }
            if preview.hidden > 0 {
                Text("\(preview.hidden) more lines")
                    .font(Fonts.caption)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 4)
            }
            if preview.lines.isEmpty {
                Text("No line changes").foregroundStyle(Palette.tertiary)
            }
        }
        .font(Fonts.code)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well))
    }
}

// MARK: - Question

/// Answers an `AskUserQuestion` from the notch. A single-choice question answers on click; a
/// multi-choice one collects ticks and continues with Next. Several questions step through one at
/// a time, and the answers go back to Claude together.
struct QuestionCard: View {
    @EnvironmentObject private var model: NotchModel
    let ask: QuestionAsk
    let agent: AgentLabel
    let waiting: Int

    @State private var index = 0
    /// Question text → chosen label(s), as Claude Code expects them.
    @State private var answers: [String: String] = [:]
    /// Ticks on the current multi-choice question.
    @State private var picked: Set<String> = []

    private var isLast: Bool { index == ask.questions.count - 1 }

    var body: some View {
        let question = ask.questions[index]
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(agent: agent, action: "Has a question for you", waiting: waiting, since: ask.receivedAt)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(question.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if ask.questions.count > 1 {
                        Text("\(index + 1) of \(ask.questions.count)")
                            .font(Fonts.caption)
                            .foregroundStyle(Palette.tertiary)
                            .monospacedDigit()
                    }
                }
                VStack(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { number, option in
                        OptionRow(option: option, multiSelect: question.multiSelect,
                                  selected: isSelected(option.label, in: question), key: "\(number + 1)") {
                            choose(option.label, in: question)
                        }
                    }
                }
            }
            .id(index)
            .transition(.opacity)
            HStack(spacing: 8) {
                Button { model.answerInTerminal(ask.id, sessionId: ask.sessionId) } label: {
                    HintedLabel(title: "Answer in terminal", key: "T")
                }
                .buttonStyle(.plain)
                .font(Fonts.caption)
                .foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                if index > 0 {
                    Button { back() } label: { HintedLabel(title: "Back", key: "⌫") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                if question.multiSelect {
                    Button { commitTicks(for: question) } label: { HintedLabel(title: isLast ? "Submit" : "Next", key: "↩") }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(picked.isEmpty)
                        .opacity(picked.isEmpty ? 0.4 : 1)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: index)
        .onChange(of: model.keySignal) { _, signal in
            if let signal { handle(signal.key) }
        }
    }

    /// Keys from the hotkey mode: 1–9 pick an option, ↩ continues a multi-choice question, ⌫ goes back.
    private func handle(_ key: NotchKey) {
        let question = ask.questions[index]
        switch key {
        case .character(let character):
            guard let number = character.wholeNumberValue, (1...question.options.count).contains(number) else { return }
            choose(question.options[number - 1].label, in: question)
        case .return where question.multiSelect && !picked.isEmpty:
            commitTicks(for: question)
        case .delete where index > 0:
            back()
        default:
            break
        }
    }

    private func isSelected(_ label: String, in question: QuestionAsk.Question) -> Bool {
        question.multiSelect ? picked.contains(label) : answers[question.text] == label
    }

    private func choose(_ label: String, in question: QuestionAsk.Question) {
        if question.multiSelect {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            answers[question.text] = label
            advance()
        }
    }

    /// Multi-select answers are the ticked labels, in option order, joined with commas.
    private func commitTicks(for question: QuestionAsk.Question) {
        answers[question.text] = question.options.map(\.label).filter(picked.contains).joined(separator: ", ")
        advance()
    }

    private func advance() {
        guard !isLast else {
            model.answerQuestion(ask.id, answers)
            return
        }
        index += 1
        restoreTicks()
    }

    private func back() {
        index -= 1
        restoreTicks()
    }

    private func restoreTicks() {
        let question = ask.questions[index]
        let previous = answers[question.text]?.components(separatedBy: ", ") ?? []
        picked = question.multiSelect ? Set(previous) : []
    }
}

/// One answer choice: label, Claude's description of it, and a radio or tick box.
struct OptionRow: View {
    let option: QuestionAsk.Option
    let multiSelect: Bool
    let selected: Bool
    let key: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Palette.needsYou : Palette.tertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                    if let description = option.description {
                        Text(description)
                            .font(Fonts.caption)
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                KeyHint(key)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Palette.needsYou.opacity(0.14) : Color.white.opacity(hovering ? 0.09 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Palette.needsYou.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}
