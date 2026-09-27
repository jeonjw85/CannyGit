import Foundation
import Observation

struct GroupTaskReference: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var directory: String
}

struct TaskGroupStage: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name = ""
    var taskIDs: [String] = []
}

struct TaskGroupDefinition: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var repositoryID: UUID
    var name: String
    var stages: [TaskGroupStage] = [TaskGroupStage()]
    var references: [GroupTaskReference] = []

    func validateStructure() throws {
        let ids = stages.flatMap(\.taskIDs)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1...16).contains(stages.count), stages.allSatisfy({ !$0.taskIDs.isEmpty }),
            (1...32).contains(ids.count), Set(ids).count == ids.count,
            Set(references.map(\.id)) == Set(ids), references.count == ids.count else {
            throw ExecutionError(message: "그룹 이름과 단계별 작업을 확인하세요. 작업은 중복 없이 최대 32개, 단계는 최대 16개입니다.")
        }
    }

    func validatePlan(_ plan: [[TaskDefinition]]) throws {
        try validateStructure()
        guard plan.count == stages.count else { throw ExecutionError(message: "실행 단계가 설정과 다릅니다.") }
        for (index, tasks) in plan.enumerated() {
            guard tasks.map(\.id) == stages[index].taskIDs else { throw ExecutionError(message: "그룹의 작업 구성이 변경되었습니다.") }
            if index < plan.count - 1 && tasks.contains(where: { $0.kind == .server }) {
                throw ExecutionError(message: "서버 작업은 마지막 단계에 두세요. 앞 단계의 일회성 작업이 성공한 뒤 다음 단계를 시작합니다.")
            }
        }
    }
}

@MainActor
@Observable
final class TaskGroupRun: Identifiable {
    let id = UUID()
    let definition: TaskGroupDefinition
    let worktreeID: UUID
    let repositoryID: UUID
    let startedAt = Date()
    var endedAt: Date?
    var status: RunStatus = .preparing
    var stageIndex = 0
    var memberIDs: [UUID] = []
    var error: String?
    var isActive: Bool { [.preparing, .running, .stopping].contains(status) }
    var acceptsLaunches: Bool { status == .preparing || status == .running }

    init(definition: TaskGroupDefinition, worktree: Worktree) {
        self.definition = definition
        worktreeID = worktree.id
        repositoryID = worktree.repositoryID
    }
}
