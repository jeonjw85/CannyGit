import AppKit
import Observation

@MainActor
@Observable
final class ExecutionCoordinator {
    var directory = FileManager.default.homeDirectoryForCurrentUser
    var shell = TerminalLaunch.accountShell
    var command = ""
    private(set) var session: TerminalSession?
    private(set) var isQuitting = false
    private(set) var isStoppingAll = false
    var errorMessage: String?
    private let environment: [String: String]
    private(set) var entries: [SessionEntry] = []
    var selectedSessions: [UUID: UUID] = [:]
    var blockedWorktrees: Set<UUID> = []
    let logs = TaskLogStore()
    let groups = TaskGroupCoordinator()
    private let launcher: any TaskLaunchPreparing
    private let ports = PortService()
    private struct RunKey: Hashable { let worktreeID: UUID; let taskID: String }
    private struct Reservation {
        let id = UUID()
        var groupID: UUID?
        var restartingID: UUID?
    }
    private var reservations: [RunKey: Reservation] = [:]
    private var recentResults: [RunKey: TaskResultSummary] = [:]
    private var portMonitor: Task<Void, Never>?
    private var refreshingPorts = false
    var onWorktreeExit: ((UUID) -> Void)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         launcher: any TaskLaunchPreparing = TaskLauncher()) {
        self.environment = environment
        self.launcher = launcher
        logs.onTruncation = { [weak self] id in
            self?.entries.first(where: { $0.id == id })?.logTruncated = true
        }
    }

    var hasActiveSession: Bool { session?.isActive == true || entries.contains { $0.session.isActive } || !reservations.isEmpty || groups.hasActiveRuns }
    var pendingLaunchCount: Int { reservations.count }

    func pendingCount(worktreeID: UUID) -> Int { reservations.keys.filter { $0.worktreeID == worktreeID }.count }
    func isPreparing(_ taskID: String, worktreeID: UUID) -> Bool { reservations[RunKey(worktreeID: worktreeID, taskID: taskID)] != nil }
    func cancelPreparation(_ taskID: String, worktreeID: UUID) {
        let key = RunKey(worktreeID: worktreeID, taskID: taskID)
        reservations.removeValue(forKey: key)
    }

    private func cancelPreparations(worktreeID: UUID) {
        for key in reservations.keys where key.worktreeID == worktreeID {
            reservations.removeValue(forKey: key)
        }
    }

    func entries(for worktreeID: UUID) -> [SessionEntry] { entries.filter { $0.worktreeID == worktreeID } }

    func activeTask(_ taskID: String, worktreeID: UUID) -> SessionEntry? {
        entries.first { $0.worktreeID == worktreeID && $0.task?.id == taskID && $0.session.isActive }
    }

    func latestResult(_ taskID: String, worktreeID: UUID) -> TaskResultSummary? {
        recentResults[RunKey(worktreeID: worktreeID, taskID: taskID)]
    }

    func hasFailedTask(worktreeID: UUID) -> Bool {
        recentResults.contains { key, value in
            key.worktreeID == worktreeID && value.status == .failed && activeTask(key.taskID, worktreeID: worktreeID) == nil
        }
    }

    func openShell(worktree: Worktree, shell: String) async throws {
        guard worktree.canExecute, !blockedWorktrees.contains(worktree.id), !isQuitting, !isStoppingAll else {
            throw ExecutionError(message: "현재 워크트리에서 터미널을 시작할 수 없습니다.")
        }
        let session = TerminalSession(configuration: TerminalLaunch(executable: shell, arguments: ["-il"],
            directory: URL(fileURLWithPath: worktree.path), environment: environment), focusOnPresentation: true)
        let number = entries(for: worktree.id).filter { $0.task == nil }.count + 1
        let entry = SessionEntry(repositoryID: worktree.repositoryID, worktreeID: worktree.id,
                                 title: "shell \(number)", task: nil, session: session)
        attach(entry)
        await session.start()
    }

    @discardableResult
    func run(_ task: TaskDefinition, worktree: Worktree, shell: String, groupRunID: UUID? = nil,
             restarting: SessionEntry? = nil) async throws -> SessionEntry {
        let key = RunKey(worktreeID: worktree.id, taskID: task.id)
        let active = activeTask(task.id, worktreeID: worktree.id)
        guard (active == nil || active?.id == restarting?.id), reservations[key] == nil else {
            throw ExecutionError(message: "같은 작업이 이미 실행 중입니다.")
        }
        if let restarting {
            guard restarting.worktreeID == worktree.id, restarting.task?.id == task.id,
                entries.contains(where: { $0.id == restarting.id }) else { throw CancellationError() }
        }
        guard worktree.canExecute, !blockedWorktrees.contains(worktree.id), !isQuitting, !isStoppingAll else {
            throw ExecutionError(message: "현재 워크트리에서 작업을 시작할 수 없습니다.")
        }
        let reservation = Reservation(groupID: groupRunID, restartingID: restarting?.id)
        let token = reservation.id
        reservations[key] = reservation
        defer {
            if reservations[key]?.id == token {
                reservations.removeValue(forKey: key)
            }
        }
        let launch = try await launcher.configuration(task: task, root: URL(fileURLWithPath: worktree.path),
                                                     shell: shell, environment: environment)
        guard !Task.isCancelled, !isQuitting, !isStoppingAll, !blockedWorktrees.contains(worktree.id), reservations[key]?.id == token,
            groupRunID == nil || groups.acceptsLaunches(groupRunID!) else { throw CancellationError() }
        if let restarting {
            try await Self.stopAndWait(restarting.session)
            guard !Task.isCancelled, !isQuitting, !isStoppingAll, !blockedWorktrees.contains(worktree.id),
                reservations[key]?.id == token else { throw CancellationError() }
        }
        let session = TerminalSession(configuration: launch)
        let entry = SessionEntry(repositoryID: worktree.repositoryID, worktreeID: worktree.id,
                                 title: task.name, task: task, session: session, groupRunID: groupRunID)
        attach(entry)
        // Publish the session before awaiting any I/O so quit/duplicate-run sees it.
        await session.start()
        if !task.expectedPorts.isEmpty {
            do {
                let occupied = try await ports.conflicts(ports: task.expectedPorts)
                let owned = Set(try await session.refreshOwnedProcesses().map(\.pid))
                guard entries.contains(where: { $0.id == entry.id }) else { return entry }
                entry.conflicts = occupied.filter { !owned.contains($0.pid) }
                entry.conflictsCheckedAt = Date()
                entry.conflictError = nil
            } catch { entry.conflictError = error.localizedDescription }
        }
        return entry
    }

    func validateTask(_ task: TaskDefinition, worktree: Worktree, shell: String) async throws {
        _ = try await launcher.configuration(task: task, root: URL(fileURLWithPath: worktree.path), shell: shell, environment: environment)
    }

    func cancelGroupPreparations(_ groupID: UUID) {
        for key in reservations.keys where reservations[key]?.groupID == groupID {
            reservations.removeValue(forKey: key)
        }
    }

    func stopGroupMembers(_ groupID: UUID) async throws {
        try await Self.stopAll(entries.filter { $0.groupRunID == groupID }.map(\.session))
    }

    func close(_ entry: SessionEntry) async throws {
        if let task = entry.task {
            let key = RunKey(worktreeID: entry.worktreeID, taskID: task.id)
            if reservations[key]?.restartingID == entry.id { reservations.removeValue(forKey: key) }
        }
        try await Self.stopAndWait(entry.session)
        removeEntry(entry)
    }

    func stop(worktreeID: UUID) async throws {
        let inserted = blockedWorktrees.insert(worktreeID).inserted
        defer { if inserted { blockedWorktrees.remove(worktreeID) } }
        cancelPreparations(worktreeID: worktreeID)
        try await groups.stopAll(worktreeID: worktreeID, execution: self)
        let sessions = entries(for: worktreeID).map(\.session)
        try await Self.stopAll(sessions)
    }

    func stopEverything() async throws {
        guard !isStoppingAll else { return }
        isStoppingAll = true
        defer { isStoppingAll = false }
        reservations.removeAll()
        try await groups.stopAll(execution: self)
        try await Self.stopAll(entries.map(\.session) + (session.map { [$0] } ?? []))
    }

    func discard(worktreeID: UUID) {
        groups.forget(worktreeID: worktreeID)
        for entry in entries(for: worktreeID) where !entry.session.isActive { removeEntry(entry) }
        recentResults = recentResults.filter { $0.key.worktreeID != worktreeID }
    }

    func exportLog(_ entry: SessionEntry) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cannygit-\(entry.id).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = entry.task == nil ? entry.session.output.data : logs.data(for: entry.id)
        do { try await Task.detached { try data.write(to: url, options: .atomic) }.value }
        catch { errorMessage = error.localizedDescription }
    }

    private func attach(_ entry: SessionEntry) {
        entries.append(entry)
        groups.record(entry)
        selectedSessions[entry.worktreeID] = entry.id
        if entry.task != nil {
            let id = entry.id
            entry.session.onOutput = { [weak self] bytes in self?.logs.append(bytes, to: id) }
        }
        entry.session.onCompletion = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            entry.endedAt = Date()
            entry.ports = []
            entry.logTruncated = self.logs.isTruncated(entry.id)
            if let task = entry.task {
                self.recentResults[RunKey(worktreeID: entry.worktreeID, taskID: task.id)] = TaskResultSummary(
                    sessionID: entry.id, status: entry.status, detail: entry.resultDescription,
                    startedAt: entry.startedAt, endedAt: entry.endedAt ?? Date()
                )
                if self.recentResults.count > 200,
                    let oldest = self.recentResults.min(by: { $0.value.endedAt < $1.value.endedAt })?.key {
                    self.recentResults.removeValue(forKey: oldest)
                }
            }
            self.onWorktreeExit?(entry.worktreeID)
            self.trimHistory()
        }
        if portMonitor == nil {
            portMonitor = Task { [weak self] in
                guard let self else { return }
                repeat {
                    await self.refreshPorts()
                    try? await Task.sleep(for: .seconds(2))
                } while self.entries.contains(where: { $0.session.isActive }) && !Task.isCancelled
                self.portMonitor = nil
            }
        }
    }

    func refreshPorts() async {
        guard !refreshingPorts else { return }
        refreshingPorts = true
        defer { refreshingPorts = false }
        let active = entries.filter { $0.session.isActive }
        let identities = active.flatMap { $0.session.ownedIdentities }
        do {
            let observations = try await ports.observe(identities)
            for entry in active where entry.session.isActive {
                let owned = Set(entry.session.ownedPIDs)
                entry.ports = observations.filter { owned.contains($0.pid) }
                entry.portError = nil
                entry.portsCheckedAt = Date()
                entry.logTruncated = logs.isTruncated(entry.id)
                let output = String(decoding: entry.session.output.data.suffix(16 * 1024), as: UTF8.self)
                let pattern = #"https?://[^\s\u001B<>\"']+"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    entry.urlCandidates = Array(Set(regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
                        Range($0.range, in: output).flatMap { URL(string: String(output[$0])) }
                    })).filter { $0.host != nil }.sorted { $0.absoluteString < $1.absoluteString }
                }
            }
        } catch {
            for entry in active where entry.session.isActive { entry.portError = error.localizedDescription }
        }
        let withExpectations = active.filter { !($0.task?.expectedPorts.isEmpty ?? true) }
        let expected = Set(withExpectations.flatMap { $0.task?.expectedPorts ?? [] }).sorted()
        guard !expected.isEmpty else { return }
        do {
            let observations = try await ports.conflicts(ports: expected)
            for entry in withExpectations where entry.session.isActive {
                let owned = Set(try await entry.session.refreshOwnedProcesses().map(\.pid))
                guard entry.session.isActive else { continue }
                let expected = Set(entry.task?.expectedPorts ?? [])
                entry.conflicts = observations.filter { expected.contains($0.port) && !owned.contains($0.pid) }
                entry.conflictsCheckedAt = Date()
                entry.conflictError = nil
            }
        } catch {
            for entry in withExpectations where entry.session.isActive { entry.conflictError = error.localizedDescription }
        }
    }

    func trimHistory() {
        let finished = entries.filter { $0.task != nil && !$0.session.isActive && !groups.protectsHistory($0.groupRunID) }
        for entry in finished.prefix(max(0, finished.count - 20)) { removeEntry(entry) }
    }

    private func removeEntry(_ entry: SessionEntry) {
        entry.session.onOutput = nil
        entry.session.onCompletion = nil
        entries.removeAll { $0.id == entry.id }
        logs.remove(entry.id)
        if selectedSessions[entry.worktreeID] == entry.id {
            selectedSessions[entry.worktreeID] = entries(for: entry.worktreeID).last?.id
        }
    }

    private static func stopAndWait(_ session: TerminalSession) async throws {
        try await session.stop()
        while session.isActive && session.pid == nil { try await Task.sleep(for: .milliseconds(20)) }
        try await session.stop()
        guard !session.isActive else { throw ExecutionError(message: "세션 정리가 완료되지 않았습니다.") }
    }

    private static func stopAll(_ sessions: [TerminalSession]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in sessions { group.addTask { try await Self.stopAndWait(session) } }
            try await group.waitForAll()
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }

    func start() async {
        guard !hasActiveSession, !isQuitting else { return }
        let launch = TerminalLaunch(
            executable: shell,
            arguments: command.isEmpty ? ["-il"] : ["-lc", command],
            directory: directory,
            environment: environment
        )
        let session = TerminalSession(configuration: launch)
        errorMessage = nil
        self.session = session
        await session.start()
    }

    func stop() async {
        do { try await session?.stop() }
        catch { errorMessage = error.localizedDescription }
    }

    func prepareToQuit() async -> Bool {
        isQuitting = true
        reservations.removeAll()
        do {
            try await groups.stopAll(execution: self)
            try await Self.stopAll(entries.map(\.session) + (session.map { [$0] } ?? []))
            portMonitor?.cancel()
            return true
        } catch {
            isQuitting = false
            errorMessage = error.localizedDescription
            return false
        }
    }
}
