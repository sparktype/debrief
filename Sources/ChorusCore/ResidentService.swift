// TTS 상주 프로세스 시작/중지 라이프사이클 (pid·소켓·데몬)
import Darwin
import Foundation

public enum ResidentServiceError: Error, Equatable, Sendable {
    case alreadyRunning
    case modelUnavailable
    case notRunning
}

extension ResidentService {
    /// True when another live process already owns the resident pid file.
    public static func isForeignHostRunning(
        home: URL,
        processExists: @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> Bool {
        let paths = ChorusPaths.forHome(home)
        guard let existing = try? String(contentsOf: paths.pidURL, encoding: .utf8),
              let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid() else {
            return false
        }
        return processExists(pid)
    }
}

public actor ResidentService {
    private let home: URL
    private let modelDirectoryProvider: @Sendable (ChorusPaths) throws -> URL
    private let backendFactory: @Sendable (URL) throws -> any TTSBackend
    private let audioFactory: @Sendable () -> any AudioPlaying
    private let socketFactory: @Sendable (URL) throws -> UnixSocketServer
    private let processExists: @Sendable (Int32) -> Bool

    private var server: UnixSocketServer?
    private var daemon: ChorusDaemon?
    private var runTask: Task<Void, Error>?
    private var ownedPID: String?
    private var running = false
    private var intentionalStop = false
    /// When clearing state, remove the host pid file (full teardown) or keep it (menu Stop).
    private var removePidOnClear = true
    private var runFailure: (any Error)?

    public init(
        home: URL,
        modelDirectoryProvider: @escaping @Sendable (ChorusPaths) throws -> URL = {
            try InstalledModel.resolveCurrent(in: $0.modelsDirectory).directory
        },
        backendFactory: @escaping @Sendable (URL) throws -> any TTSBackend,
        audioFactory: @escaping @Sendable () -> any AudioPlaying,
        socketFactory: @escaping @Sendable (URL) throws -> UnixSocketServer = {
            try UnixSocketServer(socketURL: $0)
        },
        processExists: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
    ) {
        self.home = home
        self.modelDirectoryProvider = modelDirectoryProvider
        self.backendFactory = backendFactory
        self.audioFactory = audioFactory
        self.socketFactory = socketFactory
        self.processExists = processExists
    }

    public var isRunning: Bool { running }

    /// Voice ID currently synthesizing or playing, if any.
    public func activeVoice() async -> String? {
        await daemon?.activeVoice
    }

    /// Returns and clears the error that ended the run loop, if any.
    /// Intentional `stop()` does not produce a failure.
    public func consumeRunFailure() -> (any Error)? {
        defer { runFailure = nil }
        return runFailure
    }

    public func start() async throws {
        guard !running else { throw ResidentServiceError.alreadyRunning }
        let paths = ChorusPaths.forHome(home)

        // Foreign live host pid alone is alreadyRunning (socket may be gone after menu Stop).
        if let existing = try? String(contentsOf: paths.pidURL, encoding: .utf8),
           let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           pid != getpid(),
           processExists(pid) {
            throw ResidentServiceError.alreadyRunning
        }

        try FileManager.default.createDirectory(
            at: paths.pidURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let modelDirectory: URL
        do {
            modelDirectory = try modelDirectoryProvider(paths)
        } catch {
            throw ResidentServiceError.modelUnavailable
        }

        let backend: any TTSBackend
        do {
            backend = try backendFactory(modelDirectory)
        } catch {
            throw ResidentServiceError.modelUnavailable
        }

        let server = try socketFactory(paths.socketURL)
        let homeForDiagnostics = home
        let daemon = ChorusDaemon(
            source: server,
            queue: SpeechQueue(),
            backend: backend,
            audio: audioFactory(),
            configuration: { ChorusConfiguration.load(from: paths.configURL) },
            recordError: { component, code, message in
                try? Diagnostics(home: homeForDiagnostics).recordError(
                    component: component,
                    code: code,
                    message: message
                )
            }
        )

        let pid = "\(getpid())"
        try Data(pid.utf8).write(to: paths.pidURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.pidURL.path)

        self.server = server
        self.daemon = daemon
        self.ownedPID = pid
        self.running = true
        self.intentionalStop = false
        self.removePidOnClear = true
        self.runFailure = nil
        self.runTask = Task { [weak self] in
            do {
                try await daemon.run()
            } catch {
                await self?.recordRunFailure(error)
            }
            await self?.clearStateIfOwned()
        }
    }

    /// Stops the in-process daemon and closes the socket.
    /// - Parameter removePid: When `true` (default), removes the host pid file (full teardown /
    ///   headless daemon exit). When `false`, leaves the pid so Diagnostics still sees a live host
    ///   (menu bar Stop — process continues).
    public func stop(removePid: Bool = true) async {
        guard running else { return }
        intentionalStop = true
        removePidOnClear = removePid
        await daemon?.shutdown()
        runTask?.cancel()
        _ = try? await runTask?.value
        clearStateIfOwned()
    }

    public func waitUntilStopped() async {
        while running {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func recordRunFailure(_ error: any Error) {
        guard !intentionalStop else { return }
        runFailure = error
        let message: String
        if let socket = error as? UnixSocketError {
            switch socket {
            case .disconnected:
                message = "TTS 수신 루프가 종료되었습니다"
            case .systemCall(let name, let code):
                message = "소켓 \(name) 오류 (\(code))"
            default:
                message = "TTS 서비스 오류: \(socket)"
            }
        } else {
            message = "TTS 서비스 오류: \(error.localizedDescription)"
        }
        try? Diagnostics(home: home).recordError(
            component: "daemon",
            code: "run_failed",
            message: message
        )
    }

    private func clearStateIfOwned() {
        guard running else { return }
        let paths = ChorusPaths.forHome(home)
        // Close listen before release so clients fail fast and deinit unlinks the node.
        server?.requestClose()
        runTask = nil
        daemon = nil
        server = nil
        if removePidOnClear,
           let ownedPID,
           (try? String(contentsOf: paths.pidURL, encoding: .utf8)) == ownedPID {
            try? FileManager.default.removeItem(at: paths.pidURL)
        }
        // Residual sock without a live accept loop confuses hooks (connect OK, no ACK).
        if removePidOnClear {
            try? Self.removeOwnedSocketIfPresent(at: paths.socketURL)
        }
        ownedPID = nil
        running = false
        removePidOnClear = true
    }

    /// Unlinks a residual UDS path owned by this user after the accept loop ends.
    private static func removeOwnedSocketIfPresent(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { return }
        _ = Darwin.unlink(url.path)
    }
}
