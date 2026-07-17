// TTS 상주 프로세스 시작/중지 라이프사이클 (pid·소켓·데몬)
import Darwin
import Foundation

public enum ResidentServiceError: Error, Equatable, Sendable {
    case alreadyRunning
    case modelUnavailable
    case notRunning
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

    /// Returns and clears the error that ended the run loop, if any.
    /// Intentional `stop()` does not produce a failure.
    public func consumeRunFailure() -> (any Error)? {
        defer { runFailure = nil }
        return runFailure
    }

    public func start() async throws {
        guard !running else { throw ResidentServiceError.alreadyRunning }
        let paths = ChorusPaths.forHome(home)

        if let existing = try? String(contentsOf: paths.pidURL, encoding: .utf8),
           let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           pid != getpid(),
           processExists(pid),
           FileManager.default.fileExists(atPath: paths.socketURL.path) {
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
        let daemon = ChorusDaemon(
            source: server,
            queue: SpeechQueue(),
            backend: backend,
            audio: audioFactory(),
            configuration: { ChorusConfiguration.load(from: paths.configURL) }
        )

        let pid = "\(getpid())"
        try Data(pid.utf8).write(to: paths.pidURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.pidURL.path)

        self.server = server
        self.daemon = daemon
        self.ownedPID = pid
        self.running = true
        self.intentionalStop = false
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

    public func stop() async {
        guard running else { return }
        intentionalStop = true
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
    }

    private func clearStateIfOwned() {
        guard running else { return }
        let paths = ChorusPaths.forHome(home)
        runTask = nil
        daemon = nil
        server = nil
        if let ownedPID,
           (try? String(contentsOf: paths.pidURL, encoding: .utf8)) == ownedPID {
            try? FileManager.default.removeItem(at: paths.pidURL)
        }
        ownedPID = nil
        running = false
    }
}
