import Foundation

actor TaskGroupResolver {
    private let detector = TaskDetector()

    func candidates(group: TaskGroupDefinition, tree: Worktree, settings: AppSettings) async throws -> [TaskCandidate] {
        let preferences = settings.taskPreferences.first { $0.worktreeID == tree.id }
        var combined = DetectionReport()
        // A saved rule is authoritative, including a changed working directory.
        // Old detection hints must not invalidate a current worktree override.
        let configured = Set(settings.taskRules.filter {
            $0.repositoryID == tree.repositoryID && ($0.worktreeID == nil || $0.worktreeID == tree.id)
        }.map { $0.definition.id })
        for directory in Set(group.references.filter { !configured.contains($0.id) }.map(\.directory)).sorted() {
            let report = try await detector.detect(root: URL(fileURLWithPath: tree.path), directory: directory,
                preferredManager: preferences?.directory == directory ? preferences?.packageManager : nil)
            combined.candidates += report.candidates
        }
        return TaskCatalog.merge(combined, rules: settings.taskRules, repositoryID: tree.repositoryID, worktreeID: tree.id)
    }

    func resolve(group: TaskGroupDefinition, tree: Worktree, settings: AppSettings) async throws -> [[TaskDefinition]] {
        try group.validateStructure()
        let candidates = try await candidates(group: group, tree: tree, settings: settings)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = try group.stages.map { stage in
            try stage.taskIDs.map { id in
                guard let candidate = byID[id] else {
                    let name = group.references.first { $0.id == id }?.name ?? id
                    throw ExecutionError(message: "그룹의 작업을 찾을 수 없습니다: \(name)")
                }
                guard !candidate.needsPackageManager else { throw ExecutionError(message: "패키지 매니저를 선택한 뒤 그룹을 실행하세요.") }
                return candidate.definition
            }
        }
        try group.validatePlan(plan)
        return plan
    }
}
