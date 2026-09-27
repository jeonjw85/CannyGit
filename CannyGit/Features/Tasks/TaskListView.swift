import SwiftUI

struct TaskListView: View {
    @Bindable var model: DashboardModel
    let tree: Worktree
    @State private var editing: TaskDefinition?
    @State private var directory = "."
    @State private var manager = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("탐지 상대 디렉터리", text: $directory).textFieldStyle(.roundedBorder)
                Picker("실행기", selection: $manager) {
                    Text("자동").tag("")
                    ForEach(TaskDetector.managers, id: \.self) { Text($0).tag($0) }
                }.frame(width: 150)
                Button("재탐지") { detect() }.disabled(!tree.canExecute)
                Button { editing = TaskDefinition(name: "새 작업", command: .shell(""), directory: directory) }
                    label: { Image(systemName: "plus") }.help("작업 직접 등록")
                    .accessibilityIdentifier("addTask")
            }
            if let error = model.tasks.errors[tree.id] {
                Label("탐지 실패 · 이전 결과: \(error)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            ForEach(model.tasks.reports[tree.id]?.notices ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if model.tasks.loading.contains(tree.id) { ProgressView().controlSize(.small) }
            List(model.candidates(for: tree)) { candidate in
                let task = candidate.definition
                let active = model.execution.activeTask(task.id, worktreeID: tree.id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: task.kind == .server ? "network" : "play.rectangle")
                        Text(task.name).fontWeight(.semibold)
                        TaskScopeBadge(scope: candidate.scope)
                        Spacer()
                        if let active {
                            StatusBadge(status: active.status).help(active.resultDescription)
                            Button("중지") { Task { do { try await active.session.stop() } catch { model.errorMessage = error.localizedDescription } } }
                            Button("재실행") {
                                Task {
                                    do { try await model.runTask(task, worktreeID: tree.id, restarting: active) }
                                    catch is CancellationError {}
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            }
                            .disabled(model.execution.isPreparing(task.id, worktreeID: tree.id))
                        } else if model.execution.isPreparing(task.id, worktreeID: tree.id) {
                            ProgressView().controlSize(.small)
                            Button("시작 취소") { model.execution.cancelPreparation(task.id, worktreeID: tree.id) }
                        } else {
                            Button("실행") {
                                Task { do { try await model.runTask(task, worktreeID: tree.id) }
                                    catch is CancellationError {}
                                    catch { model.errorMessage = error.localizedDescription } }
                            }.disabled(candidate.needsPackageManager || !tree.canExecute)
                                .accessibilityIdentifier("runTask-\(task.name)")
                        }
                        Button { editing = task } label: { Image(systemName: "pencil") }.help("작업 편집")
                    }
                    Text(task.command.display).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                    if active == nil, let result = model.execution.latestResult(task.id, worktreeID: tree.id) {
                        HStack {
                            StatusBadge(status: result.status)
                            Text("최근 실행 · \(result.duration) · \(result.endedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.help(result.detail)
                    }
                    Text("디렉터리: \(task.directory) · \(task.kind.title)").font(.caption2).foregroundStyle(.secondary)
                    if let source = task.source { Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    if let notice = candidate.notice { Text(notice).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                    if candidate.needsPackageManager { Text("실행기를 선택한 뒤 재탐지하세요.").font(.caption).foregroundStyle(.orange) }
                }
                .padding(.vertical, 5)
                .contextMenu {
                    Button("작업 편집") { editing = task }
                    Button(candidate.scope == .worktree ? "이 워크트리 재정의 해제" : "저장소 공통 설정 초기화") {
                        Task { await model.resetTask(task, tree: tree) }
                    }.disabled(!candidate.isCustomized)
                    Button("이 워크트리에서 숨기기") { Task { await model.saveTask(task, tree: tree, shared: false, hidden: true) } }
                }
            }
            .overlay {
                if model.candidates(for: tree).isEmpty && !model.tasks.loading.contains(tree.id) {
                    ContentUnavailableView("작업을 등록하세요", systemImage: "play.rectangle",
                        description: Text("프로젝트 파일에서 명령을 탐지하거나 + 버튼으로 직접 등록할 수 있습니다."))
                }
            }
            HStack {
                Text("탐지만으로 명령을 실행하지 않습니다.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("숨긴 작업 복원") {
                    model.settings.taskRules.removeAll { $0.repositoryID == tree.repositoryID && $0.worktreeID == tree.id && $0.hidden }
                    Task { await model.save() }
                }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .onAppear {
            let preferences = model.settings.taskPreferences.first { $0.worktreeID == tree.id }
            directory = preferences?.directory ?? "."
            manager = preferences?.packageManager ?? ""
        }
        .sheet(item: $editing) { TaskEditorView(model: model, tree: tree, initial: $0) }
    }

    private func detect() {
        Task { await model.setTaskPreferences(WorktreeTaskPreferences(worktreeID: tree.id, directory: directory,
            packageManager: manager.isEmpty ? nil : manager), tree: tree) }
    }
}
