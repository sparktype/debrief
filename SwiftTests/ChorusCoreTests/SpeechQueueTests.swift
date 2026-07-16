import Foundation
import Testing
@testable import ChorusCore

@Suite("SpeechQueueTests")
struct SpeechQueueTests {
    @Test func mainEvictsQueuedSubagents() async {
        let queue = SpeechQueue(capacity: 8, duplicateWindow: .seconds(3))
        await queue.enqueue(request(.subagentStop, "one"))
        await queue.enqueue(request(.subagentStop, "two"))
        await queue.enqueue(request(.stop, "done"))

        #expect(await queue.pendingTexts == ["done"])
    }

    @Test func mainInterruptsOnlyActiveSubagent() async {
        let queue = SpeechQueue(capacity: 8, duplicateWindow: .seconds(3))

        #expect(await queue.shouldInterruptActive(
            active: request(.subagentStop, "x"),
            incoming: request(.stop, "y")
        ))
        #expect(!(await queue.shouldInterruptActive(
            active: request(.stop, "x"),
            incoming: request(.stop, "y")
        )))
        #expect(!(await queue.shouldInterruptActive(
            active: request(.subagentStop, "x"),
            incoming: request(.subagentStop, "y")
        )))
    }

    @Test func fullQueueEvictsOldestSubagentButRejectsWhenAllMain() async {
        let mixed = SpeechQueue(capacity: 3, duplicateWindow: .zero)
        await mixed.enqueue(request(.stop, "main"))
        await mixed.enqueue(request(.subagentStop, "oldest"))
        await mixed.enqueue(request(.subagentStop, "newer"))

        #expect(await mixed.enqueue(request(.subagentStop, "incoming")) == .accepted)
        #expect(await mixed.pendingTexts == ["main", "newer", "incoming"])

        let mainOnly = SpeechQueue(capacity: 2, duplicateWindow: .zero)
        await mainOnly.enqueue(request(.stop, "one"))
        await mainOnly.enqueue(request(.stop, "two"))

        #expect(await mainOnly.enqueue(request(.subagentStop, "rejected")) == .rejectedCapacity)
        #expect(await mainOnly.pendingTexts == ["one", "two"])
    }

    @Test func duplicateEnvelopeIsSuppressedOnlyInsideWindow() async throws {
        let queue = SpeechQueue(capacity: 8, duplicateWindow: .milliseconds(10))
        let duplicate = request(.subagentStop, "same")

        #expect(await queue.enqueue(duplicate) == .accepted)
        #expect(await queue.enqueue(duplicate) == .rejectedDuplicate)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await queue.enqueue(duplicate) == .accepted)
    }

    @Test func nextResumesAfterCapacityRejection() async {
        let queue = SpeechQueue(capacity: 1, duplicateWindow: .zero)
        await queue.enqueue(request(.stop, "kept"))
        #expect(await queue.enqueue(request(.subagentStop, "rejected")) == .rejectedCapacity)

        let first = await queue.next()
        #expect(first.envelope.text == "kept")

        async let waiting = queue.next()
        await Task.yield()
        #expect(await queue.enqueue(request(.subagentStop, "continued")) == .accepted)
        #expect(await waiting.envelope.text == "continued")
    }

    private func request(_ event: HookEventName, _ text: String) -> SpeechRequest {
        SpeechRequest(
            envelope: SpeechEnvelope(v: 1, text: text, voice: "F1", speed: 0.93, volume: 0.6),
            event: event,
            agentType: event == .subagentStop ? "explore" : nil
        )
    }
}
