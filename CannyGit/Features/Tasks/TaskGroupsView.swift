import SwiftUI

struct TaskGroupsView: View {
    @Bindable var model: DashboardModel
    let tree: Worktree
    @State private var editing: TaskGroupDefinition?
    @State private var removing: TaskGroupDefinition?

    private var definitions: [TaskGroupDefinition] { model.settings.taskGroups.filter { $0.repositoryID == tree.repositoryID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("저장소 공통 실행 그룹").font(.headline)
                Spacer()
                Button("그룹 추가", systemImage: "plus") {
                    editing = TaskGroupDefinition(repositoryID: tree.repositoryID, name: "새 그룹")
                }.disabled(!tree.canExecute).accessibilityIdentifier("addTaskGroup")
            }
            Text("단계는 순서대로, 같은 단계의 작업은 병렬로 실행합니다. 서버는 마지막 단계에 두세요.")
                .font(.caption).foregroundStyle(.secondary)
            List(definitions) { definition in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(definition.name).fontWeight(.semibold)
                        Spacer()
                        if let active = model.execution.groups.active(definitionID: definition.id, worktreeID: tree.id, execution: model.execution) {
                            StatusBadge(status: active.status)
                            Button("그룹 중지") { stop(active) }
                        } else {
                            Button("그룹 실행") {
                                do { try model.startGroup(definition, worktreeID: tree.id) }
                                catch { model.errorMessage = error.localizedDescription }
                            }.disabled(!tree.canExecute).accessibilityIdentifier("runGroup-\(definition.name)")
                        }
                        Button { editing = definition } label: { Image(systemName: "pencil") }.help("그룹 편집")
                    }
                    Text(definition.stages.enumerated().map { index, stage in
                        let names = stage.taskIDs.map { id in definition.references.first { $0.id == id }?.name ?? id }
                        return "\(index + 1). " + names.joined(separator: " + ")
                    }.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
                    if let run = model.execution.groups.runs.last(where: { $0.definition.id == definition.id && $0.worktreeID == tree.id }) {
                        GroupRunDetails(model: model, run: run)
                    }
                }.padding(.vertical, 6)
                .contextMenu {
                    Button("그룹 편집") { editing = definition }
                    Button("그룹 설정 삭제", role: .destructive) { removing = definition }
                }
            }
            .overlay {
                if definitions.isEmpty { ContentUnavailableView("실행 그룹을 만드세요", systemImage: "square.stack.3d.up",
                    description: Text("예: 설치 → 프런트엔드 + 백엔드")) }
            }
        }.padding(12)
        .sheet(item: $editing) { TaskGroupEditor(model: model, tree: tree, initial: $0) }
        .alert("그룹 설정을 삭제할까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("삭제", role: .destructive) {
                if let removing { Task { do { try await model.deleteGroup(removing) } catch { model.errorMessage = error.localizedDescription } } }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private func stop(_ run: TaskGroupRun) {
        Task { do { try await model.execution.groups.stop(run, execution: model.execution) } catch { model.errorMessage = error.localizedDescription } }
    }
}

struct GroupRunDetails: View {
    @Bindable var model: DashboardModel
    let run: TaskGroupRun

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                StatusBadge(status: run.status)
                Text("단계 \(run.stageIndex + 1) / \(run.definition.stages.count) · 시작한 작업 \(run.memberIDs.count)개")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let entry = model.execution.entries.last(where: { $0.groupRunID == run.id }) {
                    Button("출력 보기") { model.revealSession(entry, stayInActivity: model.showActivity) }
                        .font(.caption)
                }
            }
            if let error = run.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
