import AgentNotchCore
import AppKit

/// AgentNotch — shows running Claude Code sessions in the notch and answers their permission
/// requests.
///
///   AgentNotch                 run the app (what the .app bundle does)
///   AgentNotch hooks           print the hook settings for `claude --settings` / settings.json
///   AgentNotch snapshot DIR    render every UI state to PNGs in DIR
@main
@MainActor
enum AgentNotchMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "hooks":
            FileHandle.standardOutput.write(HookConfig.settingsJSON())
        case "snapshot":
            exit(Snapshot.run(outputDirectory: args.dropFirst().first ?? "snapshots"))
        case "help", "--help", "-h":
            print("usage: AgentNotch [hooks | snapshot DIR]")
        default:
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchModel()
    private let server = HookServer(port: HookConfig.port)
    private var notch: NotchController?
    private var livenessTimer: Timer?
    private var sessionsTimer: Timer?
    private var tabNamesTimer: Timer?
    private var nudgeTimer: Timer?
    private var hotKey: HotKey?
    private var signalSources: [DispatchSourceSignal] = []
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController(model: model)

        server.onRequest = { [weak self] request, responder in
            MainActor.assumeIsolated { self?.handle(request, responder) }
        }
        server.onReady = {
            // Only once we can answer: from here on Claude Code sessions report to the notch.
            HookInstaller.install()
        }
        server.onFailure = { error in
            // Almost always "address in use": another AgentNotch is already running.
            FileHandle.standardError.write(Data("AgentNotch: can't listen on port \(HookConfig.port): \(error)\n".utf8))
            exit(1)
        }
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("AgentNotch: \(error)\n".utf8))
            exit(1)
        }

        livenessTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLiveness() }
        }
        // Every open agent, including ones that haven't sent a hook event since the notch started.
        model.syncOpenSessions(SessionFiles.open())
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.syncOpenSessions(SessionFiles.open()) }
        }
        model.refreshTabNames()
        tabNamesTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshTabNames() }
        }

        // Check often enough for the reminder delay (every 15s for the usual 3 minutes).
        let nudgeCheck = min(15, max(1, Preferences.nudgeAfter / 3))
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: nudgeCheck, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.nudgeIfWaiting() }
        }

        // ⌥Space opens the notch for the keyboard.
        hotKey = HotKey { [weak self] in
            DispatchQueue.main.async { self?.model.toggleKeyboard() }
        }
        if hotKey == nil {
            FileHandle.standardError.write(Data("AgentNotch: ⌥Space is taken by another app; no hotkey\n".utf8))
        }

        // `pkill AgentNotch` (the Stop script) and Ctrl-C quit through the normal path, so the
        // hooks are removed either way.
        for signal in [SIGTERM, SIGINT] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                Log.debug("signal \(signal): quitting")
                // Not from inside this main-queue block: terminate waits on a nested run loop,
                // which can't drain the main queue while we're still in it.
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.debug("applicationShouldTerminate (quitting=\(quitting))")
        guard !quitting else { return .terminateLater }
        quitting = true
        HookInstaller.uninstall()
        model.releaseAll()
        // Keep answering for a moment while running sessions notice the hooks are gone, so
        // none of them sees a refused connection.
        // A run-loop timer in common modes fires while AppKit waits for the reply.
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            Log.debug("grace period over: terminating")
            sender.reply(toApplicationShouldTerminate: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// Clears sessions whose `claude` process has exited without telling us.
    private func checkLiveness() {
        let running = Set(ClaudeProcesses.workingDirectories().map(Self.canonical))
        let gone = model.reap { session in
            guard let cwd = session.cwd else { return true }
            return running.contains(Self.canonical(cwd))
        }
        if !gone.isEmpty { Log.debug("cleared sessions with no claude process: \(gone)") }
        model.prune()
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func handle(_ request: HTTPRequest, _ responder: Responder) {
        Log.debug("\(request.method) \(request.path) \(request.body.count)B")
        switch (request.method, request.path) {
        case ("GET", "/health"):
            responder.send(text: "ok")
        case ("GET", "/debug/open") where Log.enabled:
            // Holds the panel open for a few seconds, for screenshots without a hover.
            model.forcedMode = .expanded
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak model] in model?.forcedMode = nil }
            responder.send(text: "open")
        case ("GET", "/debug/hotkey") where Log.enabled:
            // Same as pressing ⌥Space.
            model.toggleKeyboard()
            responder.send(text: "keyboard \(model.keyboardOpen ? "open" : "closed")")
        case ("GET", let path) where Log.enabled && path.hasPrefix("/debug/type/"):
            // Types into the notch as if from the keyboard: /debug/type/tri
            let text = String(path.dropFirst("/debug/type/".count)).removingPercentEncoding ?? ""
            for character in text { _ = model.handleKey(.character(character)) }
            responder.send(text: "typed \(text)")
        case ("GET", "/debug/state") where Log.enabled:
            let state = notch?.debugState() ?? [:]
            responder.send(json: (try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])) ?? Data())
        case ("POST", "/hook"):
            guard let event = try? HookEvent(data: request.body) else {
                // Never fail a hook over a payload we don't understand.
                responder.send(json: HookReply.empty)
                return
            }
            Log.debug("event \(event.name) session=\(event.sessionId) tool=\(event.toolName ?? "-")")
            guard let ask = model.receive(event) else {
                responder.send(json: HookReply.empty)
                return
            }
            hold(ask.id, responder)
        case ("POST", "/hook/question"):
            // AskUserQuestion's PreToolUse: held until it's answered on the notch.
            guard let event = try? HookEvent(data: request.body), let question = model.receiveQuestion(event) else {
                responder.send(json: HookReply.empty)
                return
            }
            Log.debug("question \(question.id) session=\(event.sessionId)")
            hold(question.id, responder)
        default:
            responder.send(text: "not found", status: 404)
        }
    }

    /// Keeps the request open until the card is answered; drops the card if Claude stops waiting.
    private func hold(_ id: UUID, _ responder: Responder) {
        responder.onGone = { [weak model] in
            Log.debug("request \(id) abandoned by Claude Code")
            MainActor.assumeIsolated { model?.abandon(id) }
        }
        model.hold(id) { body in
            Log.debug("request \(id) answered: \(String(decoding: body, as: UTF8.self).prefix(200))")
            responder.send(json: body)
        }
        responder.watchForClose()
    }
}

/// `AGENTNOTCH_DEBUG=1 ~/Applications/AgentNotch.app/Contents/MacOS/AgentNotch` logs every request.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["AGENTNOTCH_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let time = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        FileHandle.standardError.write(Data("\(time) \(message())\n".utf8))
    }
}
