import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @Bindable var model: DashboardModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @State private var creating: Repository?
    @State private var removing: Worktree?
    @State private var unregistering: Repository?
    @State private var renaming: Repository?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.settingsError {
                HStack {
                    Label("설정을 읽지 못했습니다: \(error)", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("다시 읽기") { Task { await model.load() } }
                    Button("이전 설정 복구") { Task { await model.load(restoreBackup: true) } }
                }.padding().background(.yellow.opacity(0.12))
            }
            if let error = model.saveError {
                HStack {
                    Label("저장되지 않은 변경: \(error)", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("저장 다시 시도") { Task { await model.save() } }
                    Button("설정 다시 읽기") { Task { await model.reloadSettings() } }
                }.padding(8).background(.orange.opacity(0.12))
            }
            VSplitView {
                if model.terminalPresentation != .maximized {
                    if model.showActivity {
                        NavigationSplitView {
                            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                        } detail: { ActivityView(model: model) }
                        .frame(minHeight: 330)
                    } else {
                        NavigationSplitView {
                            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                        } content: {
                            worktreeList.navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 420)
                        } detail: {
                            if let tree = model.selectedWorktree {
                                WorktreeDetailView(model: model, tree: tree, onRemove: { removing = tree })
                            } else {
                                ContentUnavailableView("워크트리 선택", systemImage: "arrow.triangle.branch",
                                    description: Text("저장소의 브랜치와 개발 작업을 한곳에서 관리합니다."))
                            }
                        }
                        .frame(minHeight: 330)
                    }
                }
                if model.terminalPresentation != .hidden {
                    TerminalPanel(model: model).frame(minHeight: 160, idealHeight: 280)
                }
            }
            .disabled(!model.isLoaded)
        }
        .frame(minWidth: 1040, minHeight: 720)
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        .searchable(text: $model.search, prompt: "이름·브랜치·경로 검색")
        .toolbar {
            ToolbarItemGroup {
                if model.isRegistering || !model.loadingRepositories.isEmpty { ProgressView().controlSize(.small) }
                Button { model.chooseRepository() } label: { Label("저장소 등록", systemImage: "folder.badge.plus") }
                    .disabled(!model.isLoaded).accessibilityIdentifier("registerRepository")
                Button { Task { await model.refreshAll() } } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                    .disabled(!model.isLoaded)
                Button { creating = model.selectedRepository } label: { Label("워크트리 생성", systemImage: "plus") }
                    .disabled(!model.isLoaded || model.showActivity || model.selectedRepository == nil).accessibilityIdentifier("createWorktree")
                Button {
                    model.terminalPresentation = model.terminalPresentation == .hidden ? .normal : .hidden
                } label: { Label("터미널 표시 전환", systemImage: "rectangle.bottomthird.inset.filled") }
                    .accessibilityIdentifier("toggleTerminalPanel")
                languagePicker
            }
        }
        .sheet(item: $creating) { CreateWorktreeSheet(model: model, repository: $0) }
        .sheet(item: $removing) { RemoveWorktreeSheet(model: model, tree: $0) }
        .sheet(item: $renaming) { repository in
            VStack(alignment: .leading, spacing: 16) {
                Text("저장소 이름").font(.headline)
                TextField("표시 이름", text: $renameText).textFieldStyle(.roundedBorder)
                HStack {
                    Button("취소") { renaming = nil }
                    Spacer()
                    Button("저장") { Task { await model.renameRepository(repository.id, name: renameText); renaming = nil } }
                        .disabled(renameText.isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360)
        }
        .alert("저장소 등록을 해제할까요?", isPresented: Binding(
            get: { unregistering != nil }, set: { if !$0 { unregistering = nil } }
        )) {
            Button("등록 해제", role: .destructive) {
                guard let repository = unregistering else { return }
                Task { do { try await model.unregister(repository) } catch { model.errorMessage = error.localizedDescription } }
            }
            Button("취소", role: .cancel) {}
        } message: { Text("열린 세션을 정리하고 앱의 등록 정보와 작업 설정을 제거합니다. 저장소 파일은 유지됩니다.") }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(
            get: { model.errorMessage != nil || model.execution.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil; model.execution.errorMessage = nil } }
        )) { Button("확인", role: .cancel) {} }
        message: { Text(model.errorMessage ?? model.execution.errorMessage ?? "") }
        .task { model.isAppActive = scenePhase == .active; await model.load(); await model.poll() }
        .onChange(of: scenePhase) { _, phase in
            model.isAppActive = phase == .active
            if phase == .active { Task { await model.refreshAll() } }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await model.refreshAll() }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<String?>(
            get: { model.showActivity ? "activity" : model.selectedRepositoryID?.uuidString ?? (model.favoritesOnly ? "favorites" : "all") },
            set: { value in
                if value == "activity" { model.showActivity = true }
                else { model.selectRepository(value.flatMap(UUID.init(uuidString:)), favorites: value == "favorites") }
            }
        )) {
            Label("전체 저장소", systemImage: "square.grid.2x2").tag("all")
            Label("즐겨찾기", systemImage: "star").tag("favorites")
            Label("실행 현황", systemImage: "play.rectangle.on.rectangle").tag("activity")
            Section("저장소") {
                ForEach(model.settings.repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { repository in
                    HStack {
                        Image(systemName: repository.favorite ? "star.fill" : "folder")
                            .foregroundStyle(repository.favorite ? .yellow : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(repository.name).lineLimit(1)
                            if model.repositoryErrors[repository.id] != nil {
                                Text("접근 불가 · 재연결 필요").font(.caption2).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        let count = model.execution.entries.filter { $0.repositoryID == repository.id && $0.task != nil && $0.session.isActive }.count
                        if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.green) }
                    }
                    .tag(repository.id.uuidString)
                    .contextMenu {
                        Button(repository.favorite ? "즐겨찾기 해제" : "즐겨찾기 추가") { model.toggleFavorite(repository) }
                        Button("이름 변경") { renameText = repository.name; renaming = repository }
                        Button("경로 복사") { model.copyPath(repository.path) }
                        Button("다시 연결") { model.chooseRepository(reconnecting: repository.id) }
                        Divider()
                        Button("등록 해제", role: .destructive) { unregistering = repository }
                    }
                    .help(repository.path)
                }
            }
        }
        .navigationTitle("CannyGit")
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isLoaded else { return false }
            Task {
                for url in urls where url.isFileURL {
                    do { try await model.register(url) } catch { model.errorMessage = error.localizedDescription }
                }
            }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            Button("저장소 등록", systemImage: "plus") { model.chooseRepository() }
                .buttonStyle(.borderless).padding().frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!model.isLoaded)
        }
    }

    private var languagePicker: some View {
        Picker(selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.requestChange(to: $0) })) {
            Text(verbatim: "English").tag(AppLanguage.english)
            Text(verbatim: "한국어").tag(AppLanguage.korean)
        } label: {
            Label("언어", systemImage: "globe")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("언어")
        .accessibilityIdentifier("appLanguage")
    }

    @ViewBuilder private var worktreeList: some View {
        if model.settings.repositories.isEmpty {
            ContentUnavailableView {
                Label("저장소 등록", systemImage: "folder.badge.plus")
            } description: { Text("기존 Git 저장소 폴더를 선택하거나 사이드바에 끌어 놓기") }
            actions: { Button("폴더 선택") { model.chooseRepository() }.disabled(!model.isLoaded) }
        } else {
            VStack(spacing: 0) {
                Picker("워크트리 필터", selection: $model.worktreeFilter) {
                    ForEach(DashboardFilter.allCases) { Text($0.title).tag($0) }
                }.padding(10).accessibilityIdentifier("worktreeFilter")
                if let repository = model.selectedRepository, let error = model.repositoryErrors[repository.id] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("다시 연결") { model.chooseRepository(reconnecting: repository.id) }
                    }.padding()
                }
                List(selection: Binding(get: { model.selectedWorktreeID }, set: { model.selectWorktree($0) })) {
                    ForEach(model.settings.repositories.sorted { $0.name < $1.name }) { repository in
                        let trees = model.visibleWorktrees.filter { $0.repositoryID == repository.id }
                        if !trees.isEmpty {
                            Section(repository.name) {
                                ForEach(trees) { tree in
                                    WorktreeRow(tree: tree, entries: model.execution.entries(for: tree.id))
                                        .tag(tree.id).accessibilityIdentifier("worktree-\(tree.displayName)")
                                        .contextMenu {
                                            Button("Finder에서 열기") { model.reveal(tree) }
                                            Button("에디터에서 열기") { model.openEditor(tree) }
                                            Button("경로 복사") { model.copyPath(tree.path) }
                                            Button("워크트리 삭제", role: .destructive) { removing = tree }
                                                .disabled(tree.isMain || tree.isBare || tree.locked != nil)
                                        }
                                }
                            }
                        }
                    }
                }
                .environment(\.defaultMinListRowHeight, 64)
                .overlay {
                    if model.visibleWorktrees.isEmpty && model.loadingRepositories.isEmpty {
                        ContentUnavailableView("표시할 워크트리가 없습니다", systemImage: "magnifyingglass",
                            description: Text("검색 조건과 저장소 경로 확인"))
                    }
                }
            }
            .navigationTitle("워크트리")
        }
    }
}

private struct WorktreeRow: View {
    let tree: Worktree
    let entries: [SessionEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: tree.isMain ? "house" : "arrow.triangle.branch")
                Text(tree.displayName).fontWeight(.medium).lineLimit(1)
                Spacer()
                if tree.locked != nil { Image(systemName: "lock") }
            }
            Text(tree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                if tree.isMissing { Text("경로 누락").foregroundStyle(.red) }
                else if tree.error != nil { Text("조회 실패 · 이전 상태").foregroundStyle(.orange) }
                else if let status = tree.status {
                    if status.isUnborn { Text("첫 커밋 전") }
                    else if status.isClean { Text("clean").foregroundStyle(.green) }
                    else { Text("변경 \(status.files.count)항목").foregroundStyle(.orange) }
                    if status.conflicts > 0 { Text("충돌 \(status.conflicts)").foregroundStyle(.red) }
                } else { Text(tree.isBare ? "bare" : "조회 중") }
                Spacer()
                if let port = entries.flatMap(\.ports).first { Text(":\(port.port)").foregroundStyle(.blue) }
                else if entries.contains(where: { $0.session.isActive }) { Image(systemName: "play.circle.fill").foregroundStyle(.green) }
            }.font(.caption2)
        }.padding(.vertical, 4)
    }
}
