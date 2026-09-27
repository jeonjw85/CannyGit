import SwiftUI

struct CreateWorktreeSheet: View {
    @Bindable var model: DashboardModel
    let repository: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var existing = false
    @State private var branch = ""
    @State private var existingBranch = ""
    @State private var startPoint = ""
    @State private var path = ""
    @State private var automaticPath = true
    @State private var branches: [GitBranch] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("워크트리 생성").font(.title2.bold())
            Text(repository.name).foregroundStyle(.secondary)
            Picker("브랜치", selection: $existing) {
                Text("새 브랜치").tag(false)
                Text("기존 로컬 브랜치").tag(true)
            }.pickerStyle(.segmented)
            if existing {
                Picker("로컬 브랜치", selection: $existingBranch) {
                    Text("선택하세요").tag("")
                    ForEach(branches.filter(\.isLocal)) { branch in
                        Text(branch.name + (occupied(branch.ref) ? " · 사용 중" : ""))
                            .tag(branch.name).disabled(occupied(branch.ref))
                    }
                }
            } else {
                TextField("새 브랜치 이름", text: $branch).accessibilityIdentifier("newBranchName")
                Picker("기준 브랜치", selection: $startPoint) {
                    Text("선택하세요").tag("")
                    ForEach(branches) { Text($0.name).tag($0.ref) }
                }
            }
            TextField("생성할 절대 경로", text: Binding(get: { path }, set: { path = $0; automaticPath = false }))
                .accessibilityIdentifier("newWorktreePath")
            Text("브랜치 이름과 폴더 이름은 별개입니다. 경로를 직접 수정할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if branches.isEmpty { Text("기준 브랜치가 없습니다. 첫 커밋이 있는 저장소인지 확인하세요.").foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("생성") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(busy || path.isEmpty || (existing ? existingBranch.isEmpty : branch.isEmpty || startPoint.isEmpty))
                    .accessibilityIdentifier("confirmCreateWorktree")
            }
        }
        .textFieldStyle(.roundedBorder).padding(24).frame(width: 560)
        .interactiveDismissDisabled(busy)
        .task {
            do {
                branches = try await model.git.branches(repository, executable: model.settings.gitPath)
                startPoint = branches.first(where: { $0.ref == "refs/heads/main" })?.ref ?? branches.first?.ref ?? ""
            } catch { self.error = error.localizedDescription }
            updatePath()
        }
        .onChange(of: branch) { _, _ in updatePath() }
        .onChange(of: existingBranch) { _, _ in updatePath() }
        .onChange(of: existing) { _, _ in updatePath() }
    }

    private func occupied(_ ref: String) -> Bool { model.worktrees.contains { $0.repositoryID == repository.id && $0.branchRef == ref } }
    private func updatePath() {
        guard automaticPath else { return }
        let value = (existing ? existingBranch : branch).replacingOccurrences(of: "/", with: "-")
        let source = URL(fileURLWithPath: repository.path)
        path = source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + "-worktrees")
            .appendingPathComponent(value.isEmpty ? "new-worktree" : value).path
    }

    private func create() {
        busy = true
        error = nil
        Task {
            do {
                try await model.createWorktree(repository: repository, branch: existing ? existingBranch : branch,
                                              startPoint: startPoint, path: path, existing: existing)
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct RemoveWorktreeSheet: View {
    @Bindable var model: DashboardModel
    let tree: Worktree
    @Environment(\.dismiss) private var dismiss
    @State private var preview: RemovalPreview?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("워크트리 폴더 삭제", systemImage: "trash").font(.title2.bold())
            Text(tree.path).font(.callout.monospaced()).textSelection(.enabled)
            Text("이 폴더 전체가 제거됩니다. 브랜치는 유지됩니다. 열린 작업과 터미널은 먼저 정리합니다.")
            let active = model.execution.entries(for: tree.id).filter { $0.session.isActive }.count
                + model.execution.pendingCount(worktreeID: tree.id)
            Text("정리할 실행 세션: \(active)개")
            if let preview {
                if !preview.ignoredPaths.isEmpty {
                    Label("ignored 항목도 삭제됩니다 (\(preview.ignoredPaths.count)항목).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    ScrollView { Text(preview.ignoredPaths.prefix(30).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
                        .frame(maxHeight: 130)
                }
            } else if error == nil { ProgressView("삭제 가능 여부 확인 중") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("폴더 삭제", role: .destructive) {
                    busy = true
                    Task {
                        do { try await model.removeWorktree(tree); dismiss() }
                        catch { self.error = error.localizedDescription; preview = nil }
                        busy = false
                    }
                }.disabled(preview == nil || busy).accessibilityIdentifier("confirmRemoveWorktree")
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(busy)
        .task {
            guard let repository = model.settings.repositories.first(where: { $0.id == tree.repositoryID }) else { return }
            do { preview = try await model.git.removalPreview(repository: repository, worktree: tree, executable: model.settings.gitPath) }
            catch { self.error = error.localizedDescription }
        }
    }
}
