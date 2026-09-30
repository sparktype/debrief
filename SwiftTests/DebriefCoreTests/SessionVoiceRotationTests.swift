import Foundation
import Testing
@testable import DebriefCore

@Suite("SessionVoiceRotationTests")
struct SessionVoiceRotationTests {
    @Test func walksEveryVoiceThenWraps() {
        var state = SessionVoiceRotation()
        var heard: [String] = []
        for index in 0..<SessionVoiceRotation.order.count {
            heard.append(state.claim("session-\(index)"))
        }
        #expect(heard == SessionVoiceRotation.order)
        #expect(state.claim("session-wrap") == "F1")
        #expect(Set(SessionVoiceRotation.order) == VoiceCatalog.allowedVoiceIDs)
    }

    @Test func sameSessionKeepsItsVoice() {
        var state = SessionVoiceRotation()
        #expect(state.claim("alpha") == "F1")
        #expect(state.claim("beta") == "F2")
        #expect(state.claim("alpha") == "F1")
        #expect(state.claim("gamma") == "F3")
    }

    @Test func storeRemembersAcrossOpens() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "debrief-voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SessionVoiceStore(url: url)
        #expect(try first.claim("alpha") == "F1")
        let second = SessionVoiceStore(url: url)
        #expect(try second.claim("beta") == "F2")
        #expect(try second.claim("alpha") == "F1")
    }
}
