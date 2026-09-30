import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable, Sendable {
    case pathTooLong
    case unsafeExistingPath
    case payloadTooLarge
    case invalidFrame
    case rejected
    case disconnected
    case systemCall(String, Int32)
}

public final class UnixSocketServer: @unchecked Sendable {
    public static let maximumPayloadBytes = 16 * 1024

    private let socketURL: URL
    private let fileDescriptor: Int32
    private let stateLock = NSLock()
    private var closed = false

    public init(socketURL: URL) throws {
        self.socketURL = socketURL
        let fileManager = FileManager.default
        let directory = socketURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Self.removeStaleSocketIfSafe(at: socketURL)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.systemCall("socket", errno)
        }
        do {
            try Self.configure(descriptor)
            var address = try Self.address(for: socketURL.path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw UnixSocketError.systemCall("bind", errno)
            }
            guard chmod(socketURL.path, 0o600) == 0 else {
                throw UnixSocketError.systemCall("chmod", errno)
            }
            guard Darwin.listen(descriptor, 8) == 0 else {
                throw UnixSocketError.systemCall("listen", errno)
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw UnixSocketError.systemCall("fcntl(O_NONBLOCK)", errno)
            }
            fileDescriptor = descriptor
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(socketURL.path)
            throw error
        }
    }

    deinit {
        Darwin.close(fileDescriptor)
        var info = stat()
        if lstat(socketURL.path, &info) == 0,
           (info.st_mode & S_IFMT) == S_IFSOCK,
           info.st_uid == geteuid() {
            Darwin.unlink(socketURL.path)
        }
    }

    public func accept() async throws -> SpeechRequest {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.acceptOne())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func requestClose() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    private func acceptOne() throws -> SpeechRequest {
        var descriptor: Int32
        while true {
            descriptor = Darwin.accept(fileDescriptor, nil, nil)
            if descriptor >= 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if isClosed { throw UnixSocketError.disconnected }
                var event = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&event, 1, 100)
                if result < 0, errno != EINTR {
                    throw UnixSocketError.systemCall("poll", errno)
                }
                continue
            }
            if isClosed { throw UnixSocketError.disconnected }
            throw UnixSocketError.systemCall("accept", errno)
        }
        defer { Darwin.close(descriptor) }
        let acceptedFlags = fcntl(descriptor, F_GETFL)
        guard acceptedFlags >= 0,
              fcntl(descriptor, F_SETFL, acceptedFlags & ~O_NONBLOCK) == 0 else {
            throw UnixSocketError.systemCall("fcntl(blocking)", errno)
        }
        try Self.configure(descriptor)

        do {
            let header = try Self.readExactly(4, from: descriptor)
            let length = header.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(as: UInt32.self).bigEndian
            }
            guard length <= Self.maximumPayloadBytes else {
                try? Self.writeAll(Data([0x15]), to: descriptor)
                throw UnixSocketError.payloadTooLarge
            }
            let payload = try Self.readExactly(Int(length), from: descriptor)
            let request = try JSONDecoder().decode(SpeechRequest.self, from: payload)
            try Self.writeAll(Data([0x06]), to: descriptor)
            return request
        } catch UnixSocketError.payloadTooLarge {
            throw UnixSocketError.payloadTooLarge
        } catch {
            // Per-client failures (EOF, read timeout, bad JSON) must not look like listener death.
            try? Self.writeAll(Data([0x15]), to: descriptor)
            throw UnixSocketError.invalidFrame
        }
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private static func removeStaleSocketIfSafe(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketError.systemCall("lstat", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else {
            throw UnixSocketError.unsafeExistingPath
        }
        guard Darwin.unlink(url.path) == 0 else {
            throw UnixSocketError.systemCall("unlink", errno)
        }
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.pathTooLong
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return address
    }

    fileprivate static func configure(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw UnixSocketError.systemCall("setsockopt(SO_NOSIGPIPE)", errno)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 150_000)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw UnixSocketError.systemCall("setsockopt(timeout)", errno)
            }
        }
    }

    fileprivate static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let result = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw UnixSocketError.disconnected
            } else if errno != EINTR {
                throw UnixSocketError.systemCall("read", errno)
            }
        }
        return data
    }

    fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if result > 0 {
                offset += result
            } else if result < 0 && errno != EINTR {
                throw UnixSocketError.systemCall("write", errno)
            }
        }
    }
}

public struct UnixSocketClient: SpeechSink, Sendable {
    private let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public func submit(_ request: SpeechRequest) async throws {
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= UnixSocketServer.maximumPayloadBytes else {
            throw UnixSocketError.payloadTooLarge
        }
        let url = socketURL
        try await Task.detached(priority: .userInitiated) {
            var lastError: Error = UnixSocketError.disconnected
            for attempt in 0..<2 {
                do {
                    try Self.submit(payload, to: url)
                    return
                } catch {
                    lastError = error
                    if attempt == 0 { usleep(20_000) }
                }
            }
            throw lastError
        }.value
    }

    private static func submit(_ payload: Data, to url: URL) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.systemCall("socket", errno)
        }
        defer { Darwin.close(descriptor) }
        try UnixSocketServer.configure(descriptor)
        var address = try UnixSocketServer.address(for: url.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw UnixSocketError.systemCall("connect", errno)
        }

        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try UnixSocketServer.writeAll(header, to: descriptor)
        try UnixSocketServer.writeAll(payload, to: descriptor)
        // 서버가 부하로 느려도 ACK를 기다린다. 짧게 끊고 재시도하면 같은 발화가 두 번 들어갈 수 있다.
        var acknowledgementTimeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &acknowledgementTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw UnixSocketError.systemCall("setsockopt(timeout)", errno)
        }
        let acknowledgement = try UnixSocketServer.readExactly(1, from: descriptor)
        guard acknowledgement.first == 0x06 else { throw UnixSocketError.rejected }
    }
}

public enum HookCommandRunner {
    public static func run(input: Data, source: HostSource, home: URL) async -> Data {
        guard let event = try? HookAdapter.decode(input, source: source) else {
            return Data("{}".utf8)
        }
        let paths = DebriefPaths.forHome(home)
        let client = UnixSocketClient(socketURL: paths.socketURL)
        let result = await HookEngine(
            sink: client,
            sessionVoices: SessionVoiceStore(url: paths.sessionVoicesURL)
        ).handle(event, source: source)
        let diagnostics = Diagnostics(home: home)
        if result.submitted {
            try? diagnostics.clearCurrentError()
        } else if let deliveryError = result.deliveryError {
            try? diagnostics.recordError(
                component: "hook",
                code: result.submitted ? "ok" : "delivery_failed",
                message: "\(source.rawValue) \(event.name.rawValue): \(deliveryError)"
            )
        }
        return result.stdout
    }
}
