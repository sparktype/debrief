import CryptoKit
import Foundation

public enum QueueDecision: Equatable, Sendable {
    case accepted
    case rejectedDuplicate
    case rejectedCapacity
}

public actor SpeechQueue {
    private struct RecentDigest: Sendable {
        let value: SHA256.Digest
        let acceptedAt: ContinuousClock.Instant
    }

    private let capacity: Int
    private let duplicateWindow: Duration
    private let clock = ContinuousClock()
    private var pending: [SpeechRequest] = []
    private var waiters: [CheckedContinuation<SpeechRequest, Never>] = []
    private var recentDigests: [RecentDigest] = []

    public init(capacity: Int = 8, duplicateWindow: Duration = .seconds(3)) {
        precondition(capacity > 0, "queue capacity must be positive")
        self.capacity = capacity
        self.duplicateWindow = duplicateWindow
    }

    @discardableResult
    public func enqueue(_ request: SpeechRequest) -> QueueDecision {
        let now = clock.now
        recentDigests.removeAll {
            $0.acceptedAt.duration(to: now) >= duplicateWindow
        }
        let digest = Self.digest(request.envelope)
        guard !recentDigests.contains(where: { $0.value == digest }) else {
            return .rejectedDuplicate
        }

        if request.isMain {
            pending.removeAll { !$0.isMain }
        }

        if pending.count >= capacity {
            guard let oldestSubagent = pending.firstIndex(where: { !$0.isMain }) else {
                return .rejectedCapacity
            }
            pending.remove(at: oldestSubagent)
        }

        recentDigests.append(RecentDigest(value: digest, acceptedAt: now))
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: request)
        } else {
            pending.append(request)
        }
        return .accepted
    }

    public func next() async -> SpeechRequest {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func shouldInterruptActive(active: SpeechRequest, incoming: SpeechRequest) -> Bool {
        incoming.isMain && !active.isMain
    }

    var pendingTexts: [String] {
        pending.map(\.envelope.text)
    }

    private static func digest(_ envelope: SpeechEnvelope) -> SHA256.Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(envelope)) ?? Data()
        return SHA256.hash(data: data)
    }
}

private extension SpeechRequest {
    var isMain: Bool { event == .stop }
}
