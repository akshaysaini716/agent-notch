import Foundation

/// What a turn did, for the "finished" card: files changed and how the last test, build or lint
/// run went.
public struct TurnSummary: Equatable, Sendable {
    public var files: Set<String> = []
    public var added = 0
    public var removed = 0
    public var check: CheckResult?

    public init() {}

    public var isEmpty: Bool { files.isEmpty && check == nil }

    /// Records a tool call that finished (PostToolUse, or PostToolUseFailure with `failed`).
    public mutating func record(tool: String?, input: JSONValue?, output: String, failed: Bool) {
        guard let tool, let input else { return }
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            // A failed edit changed nothing.
            if !failed { recordEdit(tool: tool, input: input) }
        case "Bash":
            if let command = input["command"]?.string,
               let result = CheckResult.classify(command: command, output: output, failed: failed) {
                check = result   // the latest run is the one that counts
            }
        default:
            break
        }
    }

    private mutating func recordEdit(tool: String, input: JSONValue) {
        guard let path = input["file_path"]?.string ?? input["notebook_path"]?.string else { return }
        files.insert(path)
        switch tool {
        case "Write":
            added += input["content"]?.string.map(Step.lineCount) ?? 0
        case "MultiEdit":
            for edit in input["edits"]?.array ?? [] {
                let (plus, minus) = Step.editCounts(old: edit["old_string"]?.string, new: edit["new_string"]?.string)
                added += plus ?? 0
                removed += minus ?? 0
            }
        default:
            let (plus, minus) = Step.editCounts(old: input["old_string"]?.string, new: input["new_string"]?.string)
            added += plus ?? 0
            removed += minus ?? 0
        }
    }
}

/// The outcome of a test, build or lint command.
public struct CheckResult: Equatable, Sendable {
    public enum Kind: String, Sendable { case tests = "Tests", build = "Build", lint = "Lint" }

    public var kind: Kind
    public var passed: Bool
    /// The runner's own summary line, e.g. "Tests: 2 failed, 5 passed" or "BUILD SUCCESSFUL in 41s".
    public var detail: String?

    public init(kind: Kind, passed: Bool, detail: String? = nil) {
        self.kind = kind
        self.passed = passed
        self.detail = detail
    }

    /// "Tests passed", "Build failed".
    public var headline: String { "\(kind.rawValue) \(passed ? "passed" : "failed")" }

    /// Nil for commands that aren't tests, builds or linters.
    public static func classify(command: String, output: String, failed: Bool) -> CheckResult? {
        guard let kind = kind(of: command) else { return nil }
        let failedInOutput = matches(output, #"\b[1-9][0-9]* (failed|failures?|errors?)\b|BUILD FAILED|FAILURE:|Tests? failed"#)
        return CheckResult(kind: kind, passed: !failed && !failedInOutput, detail: summaryLine(output))
    }

    /// Programs that run tests, builds or linters. A command only counts when one of its steps
    /// starts with one of these, so `grep -rn test src` isn't mistaken for a test run.
    static let runners: Set<String> = [
        "gradlew", "gradle", "mvn", "mvnw", "npm", "yarn", "pnpm", "npx", "bun", "deno", "pytest", "python",
        "python3", "go", "cargo", "swift", "make", "xcodebuild", "jest", "vitest", "tsc", "eslint", "detekt",
        "ktlint", "ruff", "flake8", "mypy", "swiftlint", "golangci-lint", "dotnet", "rspec", "bundle", "mix",
        "sbt", "helm",
    ]

    static func kind(of command: String) -> Kind? {
        // The last step that runs a known runner decides (`cd x && ./gradlew test`).
        let steps = command.lowercased().components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
        for step in steps.reversed() {
            let words = step.split(separator: " ").map(String.init).drop { $0.contains("=") }   // FOO=1 cmd
            guard let program = words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }),
                  runners.contains(program) else { continue }
            if matches(step, #"\b(test|tests|pytest|jest|vitest|rspec|mocha|phpunit)\b"#) { return .tests }
            if matches(step, #"\b(lint|detekt|eslint|ktlint|ruff|flake8|mypy|swiftlint|golangci-lint)\b"#) { return .lint }
            if matches(step, #"\b(build|assemble|compile|compilekotlin|tsc|make)\b"#) || program == "make" || program == "tsc" { return .build }
        }
        return nil
    }

    /// The last line that reads like a runner's summary.
    static func summaryLine(_ output: String) -> String? {
        let pattern = #"(\b[0-9]+ (passed|failed|tests?|examples?|failures?)\b|BUILD (SUCCESSFUL|FAILED)|Tests?:|Test run with|Ran [0-9]+ tests?)"#
        let lines = LivePreview.tail(output, limit: 200)
        guard let line = lines.last(where: { matches($0, pattern) }) else { return nil }
        let cleaned = line.trimmingCharacters(in: .whitespaces)
        return cleaned.count > 70 ? String(cleaned.prefix(69)) + "…" : cleaned
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
