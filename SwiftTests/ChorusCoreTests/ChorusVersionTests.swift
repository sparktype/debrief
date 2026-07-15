import Testing
@testable import ChorusCore

@Test func versionIsSemantic() {
    #expect(ChorusVersion.current == "2.0.0")
}
