import Foundation
import Observation

@MainActor
@Observable
final class TaskGroupCoordinator {
    private(set) var runs: [TaskGroupRun] = []
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]

    var hasActiveRuns: Bool { runs.contains { $0.isActive } }
    func acceptsLaunches(_ id: UUID) -> Bool { runs.first { $0.id == id }?.acceptsLaunches == true }
    func protectsHistory(_ id: UUID?) -> Bool {
        guard let id, let run = runs.first(where: { $0.id == id }) else { return false }
        return run.isActive
    }

    func active(definitionID: UUID, worktreeID: UUID, execution: ExecutionCoordinator) -> TaskGroupRun? {
        runs.last { $0.definition.id == definitionID && $0.worktreeID == worktreeID && canStop($0, execution: execution) }
    }

    func canStop(_ run: TaskGroupRun, execution: ExecutionCoordinator) -> Bool {
        run.isActive || execution.entries.contains { $0.groupRunID == run.id && $0.session.isActive }
    }

    @discardableResult
    func start(definition: TaskGroupDefinition, worktree: Worktree, shell: String, execution: ExecutionCoordinator,
               resolve: @escaping @MainActor () async throws -> [[TaskDefinition]]) throws -> TaskGroupRun {
        guard !execution.isQuitting, !execution.isStoppingAll, !execution.blockedWorktrees.contains(worktree.id), worktree.canExecute else {
            throw ExecutionError(message: "현재 워크트리에서 그룹을 실행할 수 없습니다.")
        }
        guard definition.repositoryID == worktree.repositoryID else { throw ExecutionError(message: "다른 저장소의 그룹입니다.") }
        guard active(definitionID: definition.id, worktreeID: worktree.id, execution: execution) == nil else {
            throw ExecutionError(message: "이 워크트리에서 같은 그룹이 이미 실행 중입니다.")
        }
        try definition.validateStructure()
        let run = TaskGroupRun(definition: definition, worktree: worktree)
        runs.append(run)
        operations[run.id] = Task {
            defer {
                operations.removeValue(forKey: run.id)
                trimHistory(execution: execution)
                execution.trimHistory()
            }
            do {
                let plan = try await resolve()
                try ensureAccepting(run)
                try definition.validatePlan(plan)
                for task in plan.flatMap({ $0 }) {
                    guard execution.activeTask(task.id, worktreeID: worktree.id) == nil,
                        !execution.isPreparing(task.id, worktreeID: worktree.id) else {
                        throw ExecutionError(message: "이미 실행 중인 작업이 그룹에 포함되어 있습니다: \(task.name)")
                    }
                    try await execution.validateTask(task, worktree: worktree, shell: shell)
                    try ensureAccepting(run)
                }
                for (index, stage) in plan.enumerated() {
                    try ensureAccepting(run)
                    run.stageIndex = index
                    run.status = .running
                    let batch = try await withThrowingTaskGroup(of: SessionEntry.self) { group in
                        for task in stage {
                            group.addTask { try await execution.run(task, worktree: worktree, shell: shell, groupRunID: run.id) }
                        }
                        var entries: [SessionEntry] = []
                        for try await entry in group { entries.append(entry) }
                        return entries
                    }
                    while true {
                        try ensureAccepting(run)
                        if let failed = batch.first(where: { !$0.session.isActive && ($0.session.exit != .code(0) || $0.session.wasStopped) }) {
                            if failed.session.wasStopped { throw CancellationError() }
                            throw ExecutionError(message: "그룹 작업 실패: \(failed.title) · \(failed.resultDescription)")
                        }
                        if batch.allSatisfy({ !$0.session.isActive }) { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                run.status = .succeeded
                run.endedAt = Date()
            } catch {
                let cancelled = error is CancellationError || run.status == .stopping || run.status == .stopped
                execution.cancelGroupPreparations(run.id)
                do { try await execution.stopGroupMembers(run.id) }
                catch { run.error = error.localizedDescription }
                if !cancelled { run.error = run.error ?? error.localizedDescription }
                run.status = cancelled && run.error == nil ? .stopped : .failed
                run.endedAt = Date()
            }
        }
        return run
    }

    func record(_ entry: SessionEntry) {
        if let id = entry.groupRunID, let run = runs.first(where: { $0.id == id }) { run.memberIDs.append(entry.id) }
    }

    func stop(_ run: TaskGroupRun, execution: ExecutionCoordinator) async throws {
        guard canStop(run, execution: execution) else { return }
        run.status = .stopping
        execution.cancelGroupPreparations(run.id)
        do {
            try await execution.stopGroupMembers(run.id)
            run.status = .stopped
            run.endedAt = Date()
            execution.trimHistory()
        } catch {
            run.status = .failed
            run.error = error.localizedDescription
            throw error
        }
    }

    func stopAll(worktreeID: UUID? = nil, execution: ExecutionCoordinator) async throws {
        for run in runs where (worktreeID == nil || run.worktreeID == worktreeID) && canStop(run, execution: execution) {
            try await stop(run, execution: execution)
        }
    }

    func forget(worktreeID: UUID) { runs.removeAll { $0.worktreeID == worktreeID && !$0.isActive } }

    func waitForSettlement(_ id: UUID) async { await operations[id]?.value }

    private func ensureAccepting(_ run: TaskGroupRun) throws {
        guard acceptsLaunches(run.id) else { throw CancellationError() }
    }

    private func trimHistory(execution: ExecutionCoordinator) {
        let ended = runs.filter { !canStop($0, execution: execution) }
        let removed = Set(ended.prefix(max(0, ended.count - 20)).map(\.id))
        runs.removeAll { removed.contains($0.id) }
    }
}
