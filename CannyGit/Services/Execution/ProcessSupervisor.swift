import Darwin
import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    func startedNoEarlier(than other: Self) -> Bool {
        seconds > other.seconds || (seconds == other.seconds && microseconds >= other.microseconds)
    }
}

struct ProcessSnapshot: Sendable {
    let identity: ProcessIdentity
    let parentID: Int32
    let groupID: Int32
    let sessionID: Int32
    let isZombie: Bool

    static func read(_ pid: Int32) -> Self? {
        guard let info = bsdInfo(pid) else { return nil }
        guard info.pbi_uid == getuid() else { errno = EPERM; return nil }
        return Self(
            identity: ProcessIdentity(
                pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec
            ),
            parentID: Int32(info.pbi_ppid), groupID: Int32(info.pbi_pgid),
            sessionID: getsid(pid), isZombie: info.pbi_status == SZOMB
        )
    }

    static func identity(_ pid: Int32) -> ProcessIdentity? {
        guard let info = bsdInfo(pid) else { return nil }
        return ProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard count == size else {
            if count >= 0 && errno == 0 { errno = ESRCH }
            return nil
        }
        return info
    }
}

struct StopTiming: Sendable {
    var interrupt: Duration = .seconds(2)
    var terminate: Duration = .seconds(3)
    var kill: Duration = .seconds(2)
}

actor ProcessSupervisor {
    private let root: ProcessIdentity
    private let discoverProcessGroup: Bool
    private var known: Set<ProcessIdentity>

    init(root: ProcessIdentity, discoverProcessGroup: Bool = false) {
        self.root = root
        self.discoverProcessGroup = discoverProcessGroup
        self.known = [root]
    }

    func members() throws -> [ProcessSnapshot] {
        var processes = try Self.snapshot()
        let observedIDs = Set(processes.map { $0.identity.pid })
        for identity in known where !observedIDs.contains(identity.pid) {
            if let current = ProcessSnapshot.read(identity.pid) {
                if current.identity == identity { processes.append(current) }
            } else if errno != ESRCH && errno != ENOENT && ProcessSnapshot.identity(identity.pid) == identity {
                throw ExecutionError(message: "소유 프로세스 \(identity.pid)의 상태를 읽을 수 없습니다.")
            }
        }
        let rootNow = ProcessSnapshot.identity(root.pid)
        let rootMissing = Darwin.kill(root.pid, 0) != 0 && errno == ESRCH
        // A reused root PID must not authorize discovery of a new session.
        let canDiscoverSession = rootNow == root || (rootNow == nil && rootMissing)
        var owned = processes.filter {
            known.contains($0.identity)
                || (canDiscoverSession && (discoverProcessGroup ? $0.groupID == root.pid : $0.sessionID == root.pid)
                    && $0.identity.startedNoEarlier(than: root))
        }
        var ids = Set(owned.map { $0.identity.pid })
        while true {
            let children = processes.filter {
                !ids.contains($0.identity.pid) && ids.contains($0.parentID)
                    && $0.identity.startedNoEarlier(than: root)
            }
            if children.isEmpty { break }
            owned += children
            ids.formUnion(children.map { $0.identity.pid })
        }
        // Retain live ownership, not an unbounded history of every shell child.
        known = Set(owned.map(\.identity))
        return owned.filter { !$0.isZombie }
    }

    func stop(foregroundGroup: Int32?, timing: StopTiming) async throws {
        let initial = try members()
        for process in initial where process.groupID == foregroundGroup {
            try signal(process, SIGINT)
        }
        if try await waitUntilEmpty(for: timing.interrupt) { return }

        // Children first; do not lose ownership when an interactive shell exits.
        for process in try members().sorted(by: { $0.identity.pid > $1.identity.pid }) {
            try signal(process, SIGTERM)
            try signal(process, SIGCONT)
        }
        if try await waitUntilEmpty(for: timing.terminate) { return }

        let deadline = ContinuousClock.now + timing.kill
        repeat {
            for process in try members() { try signal(process, SIGKILL) }
            if try members().isEmpty { return }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        throw ExecutionError(message: "프로세스 정리가 끝나지 않았습니다. 중지를 다시 시도하세요.")
    }

    private func signal(_ process: ProcessSnapshot, _ signal: Int32) throws {
        guard let current = ProcessSnapshot.read(process.identity.pid),
            current.identity == process.identity, known.contains(current.identity), !current.isZombie
        else { return }
        if Darwin.kill(current.identity.pid, signal) != 0 && errno != ESRCH {
            throw ExecutionError.system("프로세스 \(current.identity.pid) 중지 실패")
        }
    }

    private func waitUntilEmpty(for duration: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + duration
        repeat {
            if try members().isEmpty { return true }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        return try members().isEmpty
    }

    private static func snapshot() throws -> [ProcessSnapshot] {
        var capacity = max(Int(proc_listallpids(nil, 0)) + 64, 256)
        for _ in 0..<8 {
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { throw ExecutionError.system("프로세스 목록 조회 실패") }
            if count < capacity {
                return pids.prefix(Int(count)).filter { $0 > 0 }.compactMap(ProcessSnapshot.read)
            }
            capacity *= 2
        }
        throw ExecutionError(message: "프로세스 목록이 계속 변경되어 정리를 확인할 수 없습니다.")
    }
}
