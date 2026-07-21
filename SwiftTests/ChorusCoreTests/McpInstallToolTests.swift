import Foundation
import Testing
@testable import ChorusCore

@Suite("McpInstallToolTests")
struct McpInstallToolTests {
    @Test func parseDefaultsToAllHostsAndRepair() throws {
        let args = try McpInstallTool.parseArguments([:])
        #expect(args.hosts == Set(HostSource.allCases))
        #expect(args.repair == true)
    }

    @Test func parseHostsAndRepairFlags() throws {
        let args = try McpInstallTool.parseArguments([
            "hosts": ["claude", "codex"],
            "repair": false,
        ])
        #expect(args.hosts == Set([HostSource.claude, .codex]))
        #expect(args.repair == false)
    }

    @Test func parseRejectsUnknownHost() {
        #expect(throws: (any Error).self) {
            try McpInstallTool.parseArguments(["hosts": ["claude", "windsurf"]])
        }
    }

    @Test func executeInvokesRunnerAndClearsError() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let diagnostics = Diagnostics(home: home)
        try diagnostics.recordError(component: "mcp", code: "old", message: "stale")
        let runner = FakeInstallRunner()
        let result = await McpInstallTool.execute(
            arguments: McpInstallArguments(hosts: [.claude], repair: true),
            runner: runner,
            diagnostics: diagnostics
        )
        #expect(!result.isError)
        #expect(result.message.contains("\"ok\":true"))
        #expect(result.message.contains("claude"))
        #expect(await runner.lastHosts == [.claude])
        #expect(await runner.lastRepair == true)
        #expect(diagnostics.currentError() == nil)
    }

    @Test func executeRecordsFailure() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mcp-install-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let diagnostics = Diagnostics(home: home)
        let result = await McpInstallTool.execute(
            arguments: McpInstallArguments(hosts: [.claude], repair: true),
            runner: FakeInstallRunner(shouldFail: true),
            diagnostics: diagnostics
        )
        #expect(result.isError)
        #expect(diagnostics.currentError()?.code == "install_failed")
    }
}

private actor FakeInstallRunner: McpInstallRunning {
    private let shouldFail: Bool
    private(set) var lastHosts: Set<HostSource>?
    private(set) var lastRepair: Bool?

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func install(hosts: Set<HostSource>, repair: Bool) async throws -> HostInstallResult {
        lastHosts = hosts
        lastRepair = repair
        if shouldFail {
            throw CommandError.usage("forced failure")
        }
        return HostInstallResult(codexReviewRequired: hosts.contains(.codex), preservedModifiedFiles: [])
    }
}
