import Testing
@testable import DebriefCore

@Test func versionIsSemantic() {
    #expect(DebriefVersion.current == "0.0.3")
}
