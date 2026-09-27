import Foundation

extension DashboardModel {
    func groupCandidates(_ group: TaskGroupDefinition, tree: Worktree) async throws -> [TaskCandidate] {
        let stored = try await TaskGroupResolver().candidates(group: group, tree: tree, settings: settings)
        var combined = Dictionary(candidates(for: tree).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in stored { combined[item.id] = item }
        return combined.values.sorted { $0.definition.name < $1.definition.name }
    }

    func saveGroup(_ group: TaskGroupDefinition, tree: Worktree) async throws {
        guard group.repositoryID == tree.repositoryID, isLoaded else { throw CancellationError() }
        _ = try await TaskGroupResolver().resolve(group: group, tree: tree, settings: settings)
        guard settings.repositories.contains(where: { $0.id == group.repositoryID }) else { throw CancellationError() }
        settings.taskGroups.removeAll { $0.id == group.id }
        settings.taskGroups.append(group)
        await save()
        if let saveError { throw ExecutionError(message: "그룹 설정 저장 실패: \(saveError)") }
    }

    func deleteGroup(_ group: TaskGroupDefinition) async throws {
        guard !execution.groups.runs.contains(where: { $0.definition.id == group.id && execution.groups.canStop($0, execution: execution) }) else {
            throw ExecutionError(message: "실행 중인 그룹을 먼저 중지하세요.")
        }
        settings.taskGroups.removeAll { $0.id == group.id }
        await save()
    }

    @discardableResult
    func startGroup(_ group: TaskGroupDefinition, worktreeID: UUID) throws -> TaskGroupRun {
        guard isLoaded, !isTerminating, let tree = worktrees.first(where: { $0.id == worktreeID }), tree.repositoryID == group.repositoryID else {
            throw CancellationError()
        }
        let settings = self.settings
        let run = try execution.groups.start(definition: group, worktree: tree, shell: settings.shellPath, execution: execution) {
            try await TaskGroupResolver().resolve(group: group, tree: tree, settings: settings)
        }
        if terminalPresentation == .hidden { terminalPresentation = .normal }
        return run
    }
}
