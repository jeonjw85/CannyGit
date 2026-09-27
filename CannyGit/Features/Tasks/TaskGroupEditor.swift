import SwiftUI

struct TaskGroupEditor: View {
    @Bindable var model: DashboardModel
    let tree: Worktree
    @Environment(\.dismiss) private var dismiss
    @State private var group: TaskGroupDefinition
    @State private var candidates: [TaskCandidate] = []
    @State private var error: String?
    @State private var busy = false

    init(model: DashboardModel, tree: Worktree, initial: TaskGroupDefinition) {
        self.model = model
        self.tree = tree
        _group = State(initialValue: initial)
        _candidates = State(initialValue: model.candidates(for: tree))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("실행 그룹 편집").font(.title2.bold())
            TextField("그룹 이름", text: $group.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("groupName")
            Text("앞 단계가 성공해야 다음 단계를 시작합니다. 한 단계에 선택한 작업은 동시에 실행합니다. 실패·취소 시 그룹이 시작한 세션만 정리합니다.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($group.stages) { $stage in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("단계 이름 (선택)", text: $stage.name)
                                    Button { move(stage.id, offset: -1) } label: { Image(systemName: "arrow.up") }.help("단계 위로")
                                    Button { move(stage.id, offset: 1) } label: { Image(systemName: "arrow.down") }.help("단계 아래로")
                                    Button { group.stages.removeAll { $0.id == stage.id } } label: { Image(systemName: "trash") }
                                        .disabled(group.stages.count == 1).help("단계 삭제")
                                }
                                ForEach(candidates) { candidate in
                                    Toggle(isOn: Binding(
                                        get: { stage.taskIDs.contains(candidate.id) },
                                        set: { chosen in
                                            if chosen { stage.taskIDs.append(candidate.id) }
                                            else { stage.taskIDs.removeAll { $0 == candidate.id } }
                                        }
                                    )) {
                                        HStack {
                                            Text(candidate.definition.name)
                                            Text(candidate.definition.directory).font(.caption).foregroundStyle(.secondary)
                                            Text(candidate.definition.kind.title).font(.caption).foregroundStyle(.secondary)
                                            TaskScopeBadge(scope: candidate.scope)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel(candidate.definition.name)
                                    .disabled(candidate.needsPackageManager || group.stages.contains { $0.id != stage.id && $0.taskIDs.contains(candidate.id) })
                                    .help(candidate.definition.command.display)
                                }
                                ForEach(stage.taskIDs.filter { id in !candidates.contains(where: { $0.id == id }) }, id: \.self) { id in
                                    HStack {
                                        Label(group.references.first { $0.id == id }?.name ?? id, systemImage: "exclamationmark.triangle")
                                        Button("참조 제거") { stage.taskIDs.removeAll { $0 == id } }
                                    }.foregroundStyle(.orange)
                                }
                                if candidates.isEmpty { Text("작업 탭에서 먼저 작업을 탐지하거나 등록하세요.").foregroundStyle(.secondary) }
                            }.padding(8)
                        } label: {
                            Text("단계 \((group.stages.firstIndex { $0.id == stage.id } ?? 0) + 1)")
                        }
                    }
                    Button("다음 단계 추가", systemImage: "plus") { group.stages.append(TaskGroupStage()) }
                        .disabled(group.stages.count >= 16)
                }
            }.disabled(busy)
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("저장", action: save).keyboardShortcut(.defaultAction).disabled(busy).accessibilityIdentifier("saveTaskGroup")
            }
        }.padding(24).frame(width: 680, height: 660).interactiveDismissDisabled(busy)
        .task {
            do { candidates = try await model.groupCandidates(group, tree: tree) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = group.stages.firstIndex(where: { $0.id == id }), group.stages.indices.contains(index + offset) else { return }
        group.stages.swapAt(index, index + offset)
    }

    private func save() {
        let ids = group.stages.flatMap(\.taskIDs)
        group.references = ids.compactMap { id in
            if let task = candidates.first(where: { $0.id == id })?.definition {
                return GroupTaskReference(id: task.id, name: task.name, directory: task.directory)
            }
            return group.references.first { $0.id == id }
        }
        let value = group
        busy = true
        error = nil
        Task {
            do { try await model.saveGroup(value, tree: tree); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
