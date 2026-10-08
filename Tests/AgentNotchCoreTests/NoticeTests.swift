import Foundation
import Testing
@testable import AgentNotchCore

private func event(_ name: String, _ session: String = "s1") throws -> HookEvent {
    try HookEvent(["hook_event_name": name, "session_id": session, "cwd": "/w/payments-api"])
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct NoticeTests {
    @Test func longTurnsAnnounceWhenTheyFinish() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("Stop"), at: t0.addingTimeInterval(95))
        let notice = try #require(board.notices.first)
        #expect(notice.sessionId == "s1")
        #expect(!notice.failed)
        #expect(notice.duration == 95)
    }

    /// Every finished turn announces, even a few seconds' reply.
    @Test func quickTurnsAnnounceToo() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("Stop"), at: t0.addingTimeInterval(6))
        #expect(board.notices.first?.duration == 6)
    }

    @Test func failuresAlwaysAnnounce() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("StopFailure"), at: t0.addingTimeInterval(2))
        #expect(board.notices.first?.failed == true)
    }

    @Test func oneNoticePerSessionAndTheyQueue() throws {
        var board = Board()
        for id in ["a", "b"] {
            board.apply(try event("UserPromptSubmit", id), at: t0)
            board.apply(try event("Stop", id), at: t0.addingTimeInterval(60))
        }
        board.apply(try event("UserPromptSubmit", "a"), at: t0.addingTimeInterval(61))
        board.apply(try event("Stop", "a"), at: t0.addingTimeInterval(200))
        #expect(board.notices.map(\.sessionId) == ["b", "a"])
    }

    @Test func newPromptOrExitClearsTheNotice() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("Stop"), at: t0.addingTimeInterval(60))
        board.apply(try event("UserPromptSubmit"), at: t0.addingTimeInterval(61))
        #expect(board.notices.isEmpty)
        board.apply(try event("Stop"), at: t0.addingTimeInterval(200))
        board.apply(try event("SessionEnd"), at: t0.addingTimeInterval(201))
        #expect(board.notices.isEmpty)
    }

    @Test func dismissRemovesIt() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(try event("Stop"), at: t0.addingTimeInterval(60))
        board.dismissNotice(try #require(board.notices.first).id)
        #expect(board.notices.isEmpty)
    }

    @Test func newTurnForgetsTheOldReply() throws {
        var board = Board()
        board.apply(try event("UserPromptSubmit"), at: t0)
        board.apply(TranscriptDigest(lastReply: "old answer"), to: "s1")
        board.apply(try event("UserPromptSubmit"), at: t0.addingTimeInterval(5))
        #expect(board.sessions["s1"]?.lastReply == nil)
    }
}

@Suite struct NudgeScheduleTests {
    @Test func remindsAfterTheDelayThenEveryDelay() throws {
        var board = Board()
        let ask = try #require(board.apply(try HookEvent(["hook_event_name": "PermissionRequest", "session_id": "s",
                                                          "tool_name": "Bash"]), at: t0))
        let after: TimeInterval = 180
        #expect(NudgeSchedule.due(board.attention, lastNudged: [:], at: t0.addingTimeInterval(179), after: after).isEmpty)
        #expect(NudgeSchedule.due(board.attention, lastNudged: [:], at: t0.addingTimeInterval(180), after: after) == [ask.id])
        let reminded = [ask.id: t0.addingTimeInterval(185)]
        #expect(NudgeSchedule.due(board.attention, lastNudged: reminded, at: t0.addingTimeInterval(300), after: after).isEmpty)
        #expect(NudgeSchedule.due(board.attention, lastNudged: reminded, at: t0.addingTimeInterval(365), after: after) == [ask.id])
    }

    @Test func answeredRequestsAreNeverDue() throws {
        var board = Board()
        let ask = try #require(board.apply(try HookEvent(["hook_event_name": "PermissionRequest", "session_id": "s",
                                                          "tool_name": "Bash"]), at: t0))
        board.resolve(ask.id, at: t0)
        #expect(NudgeSchedule.due(board.attention, lastNudged: [:], at: t0.addingTimeInterval(9999), after: 180).isEmpty)
    }
}
