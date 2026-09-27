import SwiftUI

struct WorktreeDetailView: View {
    private enum DetailTab { case overview, tasks, groups, changes }
    @State private var selectedTab: DetailTab = .overview
    @Bindable var model: DashboardModel
    let tree: Worktree
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.settings.repositories.first(where: { $0.id == tree.repositoryID })?.name ?? "")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tree.displayName).font(.title2.bold()).textSelection(.enabled)
                    Text(tree.path).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle).help(tree.path)
                }
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                    .disabled(tree.isMain || tree.isBare || tree.locked != nil)
                    .help("워크트리 삭제").accessibilityIdentifier("removeWorktree")
                Menu {
                    Button("Finder에서 열기") { model.reveal(tree) }
                    Button("에디터에서 열기") { model.openEditor(tree) }
                    Button("경로 복사") { model.copyPath(tree.path) }
                    Divider()
                    Button("워크트리 삭제", role: .destructive, action: onRemove)
                        .disabled(tree.isMain || tree.isBare || tree.locked != nil)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            if let error = tree.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("터미널 열기", systemImage: "terminal") {
                    Task { do { try await model.openTerminal(tree.id) }
                        catch is CancellationError {}
                        catch { model.errorMessage = error.localizedDescription } }
                }.disabled(!tree.canExecute).accessibilityIdentifier("openTerminal")
                Button("에디터 열기", systemImage: "square.and.pencil") { model.openEditor(tree) }.disabled(!tree.canExecute)
            }
            TabView(selection: $selectedTab) {
                overview.tabItem { Label("개요", systemImage: "info.circle") }.tag(DetailTab.overview)
                TaskListView(model: model, tree: tree).id("tasks-\(tree.id)")
                    .tabItem { Label("작업", systemImage: "play.rectangle") }.tag(DetailTab.tasks)
                TaskGroupsView(model: model, tree: tree).id("groups-\(tree.id)")
                    .tabItem { Label("그룹", systemImage: "square.stack.3d.up") }.tag(DetailTab.groups)
                ChangesView(model: model, tree: tree).id("changes-\(tree.id)")
                    .tabItem { Label("변경", systemImage: "doc.text.magnifyingglass") }.tag(DetailTab.changes)
            }
        }.padding(16)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Git 상태") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("역할", value: tree.isBare ? "bare" : (tree.isMain ? "메인 워크트리" : "linked worktree"))
                        LabeledContent("HEAD", value: tree.status?.isUnborn == true ? "첫 커밋 전" : String((tree.status?.head ?? tree.head ?? "—").prefix(12)))
                        if let status = tree.status {
                            LabeledContent("staged / unstaged", value: "\(status.staged) / \(status.unstaged)")
                            LabeledContent("미추적 / 충돌", value: "\(status.untracked) / \(status.conflicts)")
                            LabeledContent("upstream", value: status.upstream ?? "미설정")
                            if let ahead = status.ahead, let behind = status.behind {
                                LabeledContent("ahead / behind", value: "↑\(ahead) / ↓\(behind)")
                            }
                            Text("마지막 로컬 fetch 결과 기준입니다.").font(.caption).foregroundStyle(.secondary)
                            Text("수집: \(status.collectedAt.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let locked = tree.locked { Label("잠김: \(locked)", systemImage: "lock") }
                        if let prunable = tree.prunable { Label("prunable: \(prunable)", systemImage: "exclamationmark.triangle") }
                        if tree.isMissing { Label("경로가 없습니다. 저장소 경로를 다시 연결하세요.", systemImage: "folder.badge.questionmark") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("세션") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.execution.entries(for: tree.id).isEmpty { Text("열린 세션이 없습니다.").foregroundStyle(.secondary) }
                        ForEach(model.execution.entries(for: tree.id)) { entry in
                            HStack {
                                Text(entry.title)
                                Spacer()
                                Text(entry.resultDescription).font(.caption)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(12)
        }
    }

}
