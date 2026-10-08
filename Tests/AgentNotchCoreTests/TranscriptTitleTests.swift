import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct TranscriptTitleTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func transcript(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentnotch-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func latestAiTitleWins() throws {
        let path = try transcript([
            line(["type": "ai-title", "aiTitle": "First idea", "sessionId": "s"]),
            line(["type": "user", "message": ["content": "hi"]]),
            line(["type": "ai-title", "aiTitle": "Notch agent monitor", "sessionId": "s"]),
            line(["type": "assistant", "message": ["content": "ok"]]),
        ])
        #expect(TranscriptTitle.read(path: path) == "Notch agent monitor")
    }

    @Test func customTitleBeatsGeneratedOne() {
        let data = Data([
            line(["type": "custom-title", "customTitle": "release prep", "sessionId": "s"]),
            line(["type": "ai-title", "aiTitle": "Something else", "sessionId": "s"]),
        ].joined(separator: "\n").utf8)
        #expect(TranscriptTitle.latest(in: data) == "release prep")
    }

    @Test func findsATitleFarFromTheEndAcrossChunks() throws {
        // Title near the start, then lots of chatter: forces several backwards chunks with
        // lines cut at chunk edges.
        var lines = [line(["type": "ai-title", "aiTitle": "Old but only title", "sessionId": "s"])]
        lines += (0..<400).map { index in line(["type": "assistant", "n": index, "text": String(repeating: "x", count: 90)]) }
        let path = try transcript(lines)
        #expect(TranscriptTitle.read(path: path, chunkSize: 777) == "Old but only title")
    }

    @Test func noTitleYet() throws {
        let path = try transcript([line(["type": "user", "message": ["content": "hi"]])])
        #expect(TranscriptTitle.read(path: path) == nil)
        #expect(TranscriptTitle.read(path: "/nonexistent/x.jsonl") == nil)
    }

    @Test func boardShowsTitleOverFolder() throws {
        var board = Board()
        board.apply(try HookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                                   "cwd": "/w/payments-api", "transcript_path": "/t/s1.jsonl"]), at: Date())
        #expect(board.sessions["s1"]?.displayName == "payments-api")
        #expect(board.sessions["s1"]?.transcriptPath == "/t/s1.jsonl")
        board.setTitle("Notch agent monitor", for: "s1")
        #expect(board.sessions["s1"]?.displayName == "Notch agent monitor")
        #expect(board.sessions["s1"]?.project == "payments-api")
    }
}
