import Foundation
@testable import DebriefCore

enum Fixture {
    static func load(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: tests.appending(path: "Fixtures/Hooks/\(name)"))
    }
}

enum RecordingSinkError: Error {
    case rejected
}

actor RecordingSink: SpeechSink {
    private var requests: [SpeechRequest] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func submit(_ request: SpeechRequest) async throws {
        if shouldFail { throw RecordingSinkError.rejected }
        requests.append(request)
    }

    func recorded() -> [SpeechRequest] {
        requests
    }
}
