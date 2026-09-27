import Darwin
import Foundation

actor AsyncGate {
    private var available: Int
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, any Error> }
    private var waiters: [Waiter] = []
    init(limit: Int) { available = limit }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if available > 0 { available -= 1 }
        else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters.append(Waiter(id: id, continuation: continuation)) }
                }
            } onCancel: { Task { await self.cancelWaiter(id) } }
        }
        defer {
            if waiters.isEmpty { available += 1 }
            else { waiters.removeFirst().continuation.resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

struct ProcessRequest: Sendable {
    var executable: String
    var arguments: [String]
    var directory: URL?
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var timeout: Duration = .seconds(30)
    var outputLimit = 8 * 1024 * 1024
}

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

enum CommandFailure: Error, LocalizedError, Equatable {
    case timeout, outputLimit, pipe(Int32)
    var errorDescription: String? {
        switch self {
        case .timeout: String(localized: "명령 실행 시간이 초과되었습니다.")
        case .outputLimit: String(localized: "명령 출력 한도를 초과했습니다. 결과를 표시할 수 없습니다.")
        case .pipe(let code): String(localized: "명령 출력 읽기 실패 (\(code))")
        }
    }
}

struct CommandRunner: Sendable {
    private let gate = AsyncGate(limit: 4)

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await gate.withPermit {
            let worker = Task.detached { try await Self.execute(request) }
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
        }
    }

    private static func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        guard request.executable.hasPrefix("/"), request.outputLimit > 0,
            request.directory == nil || request.directory?.isFileURL == true,
            !(request.arguments + [request.executable, request.directory?.path ?? ""] + Array(request.environment.keys)
                + Array(request.environment.values)).contains(where: { $0.utf8.contains(0) }),
            request.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") })
        else { throw ExecutionError(message: "명령의 실행 경로 또는 인자가 올바르지 않습니다.") }
        let output = Pipe(), errors = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        let identity = try CommandProcess.spawn(request, stdout: output.fileHandleForWriting.fileDescriptor,
                                               stderr: errors.fileHandleForWriting.fileDescriptor)
        let supervisor = ProcessSupervisor(root: identity, discoverProcessGroup: true)
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let handles = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        for fd in handles { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var open = [true, true]
        var captured = [Data(), Data()]
        let deadline = ContinuousClock.now + request.timeout
        var failure: (any Error)?
        var exit: ProcessExit?
        var cleanup: Task<Void, Error>?
        var cleanupStartedAt: ContinuousClock.Instant?
        var lastScan = ContinuousClock.now - .seconds(1)
        while exit == nil || open.contains(true) {
            if exit == nil {
                var status: Int32 = 0
                let result = waitpid(identity.pid, &status, WNOHANG)
                if result == identity.pid { exit = ProcessExit(waitStatus: status) }
                else if result < 0 && errno != EINTR {
                    exit = .unavailable
                    failure = failure ?? ExecutionError.system("종료 상태 조회 실패")
                }
            }
            if failure == nil {
                if Task.isCancelled { failure = CancellationError() }
                else if ContinuousClock.now >= deadline { failure = CommandFailure.timeout }
            }
            if cleanup == nil, ContinuousClock.now - lastScan >= .milliseconds(100) {
                do { _ = try await supervisor.members() }
                catch { failure = failure ?? error }
                lastScan = .now
            }
            if failure != nil, cleanup == nil {
                // Cleanup must survive cancellation of the command's worker.
                cleanupStartedAt = .now
                cleanup = Task.detached {
                    try await supervisor.stop(foregroundGroup: nil,
                        timing: StopTiming(interrupt: .zero, terminate: .milliseconds(300), kill: .seconds(2)))
                }
            }
            if let cleanupStartedAt, ContinuousClock.now - cleanupStartedAt > .seconds(3) {
                break
            }
            var descriptors = handles.enumerated().map { index, fd in
                pollfd(fd: open[index] ? fd : -1, events: Int16(POLLIN | POLLHUP), revents: 0)
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            for index in 0..<2 where open[index] {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                let count = read(handles[index], &buffer, buffer.count)
                if count > 0 {
                    if captured[0].count + captured[1].count + count > request.outputLimit {
                        failure = failure ?? CommandFailure.outputLimit
                    } else if failure == nil {
                        captured[index].append(contentsOf: buffer.prefix(count))
                    }
                } else if count == 0 { open[index] = false }
                else if errno != EAGAIN && errno != EINTR {
                    failure = failure ?? CommandFailure.pipe(errno)
                    open[index] = false
                }
            }
        }
        if let cleanup { try await cleanup.value }
        if exit == nil {
            var status: Int32 = 0
            while waitpid(identity.pid, &status, 0) < 0 && errno == EINTR {}
        }
        if let failure { throw failure }
        let status: Int32 = switch exit {
        case .code(let code), .signal(let code): code
        default: -1
        }
        return ProcessResult(status: status, stdout: captured[0], stderr: captured[1])
    }
}
