import Testing
@testable import ChorusCore

@Test func versionIsSemantic() {
    #expect(ChorusVersion.current == "0.0.2")
}
