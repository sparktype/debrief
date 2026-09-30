import Foundation
import Testing
@testable import DebriefCore

@Suite("SpeechQueueTests")
struct SpeechQueueTests {
    @Test func mainEvictsQueuedSubagents() async {
        let queue = SpeechQueue(capacity: 8, duplicateWindow: .seconds(3))
        await queue.enqueue(request(.subagent, "one"))
        await queue.enqueue(request(.subagent, "two"))
        await queue.enqueue(request(.main, "done"))

        #expect(await queue.pendingTexts == ["done"])
    }

    @Test func mainInterruptsOnlyActiveSubagent() async {
        let queue = SpeechQueue(capacity: 8, duplicateWindow: .seconds(3))

        #expect(await queue.shouldInterruptActive(
            active: request(.subagent, "x"),
            incoming: request(.main, "y")
        ))
        #expect(!(await queue.shouldInterruptActive(
            active: request(.main, "x"),
            incoming: request(.main, "y")
        )))
        #expect(!(await queue.shouldInterruptActive(
            active: request(.subagent, "x"),
            incoming: request(.subagent, "y")
        )))
    }

    @Test func fullQueueEvictsOldestSubagentButRejectsWhenAllMain() async {
        let mixed = SpeechQueue(capacity: 3, duplicateWindow: .zero)
        await mixed.enqueue(request(.main, "main"))
        await mixed.enqueue(request(.subagent, "oldest"))
        await mixed.enqueue(request(.subagent, "newer"))

        #expect(await mixed.enqueue(request(.subagent, "incoming")) == .accepted)
        #expect(await mixed.pendingTexts == ["main", "newer", "incoming"])

        let mainOnly = SpeechQueue(capacity: 2, duplicateWindow: .zero)
        await mainOnly.enqueue(request(.main, "one"))
        await mainOnly.enqueue(request(.main, "two"))

        #expect(await mainOnly.enqueue(request(.subagent, "rejected")) == .rejectedCapacity)
        #expect(await mainOnly.pendingTexts == ["one", "two"])
    }

    @Test func duplicateEnvelopeIsSuppressedOnlyInsideWindow() async throws {
        let queue = SpeechQueue(capacity: 8, duplicateWindow: .milliseconds(10))
        let duplicate = request(.subagent, "same")

        #expect(await queue.enqueue(duplicate) == .accepted)
        #expect(await queue.enqueue(duplicate) == .rejectedDuplicate)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await queue.enqueue(duplicate) == .accepted)
    }

    @Test func nextResumesAfterCapacityRejection() async {
        let queue = SpeechQueue(capacity: 1, duplicateWindow: .zero)
        await queue.enqueue(request(.main, "kept"))
        #expect(await queue.enqueue(request(.subagent, "rejected")) == .rejectedCapacity)

        let first = await queue.next()
        #expect(first.envelope.text == "kept")

        async let waiting = queue.next()
        await Task.yield()
        #expect(await queue.enqueue(request(.subagent, "continued")) == .accepted)
        #expect(await waiting.envelope.text == "continued")
    }

    private func request(_ priority: SpeechPriority, _ text: String) -> SpeechRequest {
        SpeechRequest(
            envelope: SpeechEnvelope(v: 1, text: text, voice: "F1", speed: 0.93, volume: 0.6),
            priority: priority,
            agentType: priority == .subagent ? "explore" : nil
        )
    }
}
