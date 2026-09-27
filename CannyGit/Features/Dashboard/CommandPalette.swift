import SwiftUI

enum PaletteAction {
    case register, refresh, activity
    case repository(UUID), worktree(UUID), shell(UUID), task(UUID, String), session(UUID), url(URL)
    case group(UUID, UUID), stopGroup(UUID)
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: String
    let action: PaletteAction
    var enabled = true
}

@MainActor
enum PaletteCatalog {
    static func items(model: DashboardModel) -> [PaletteItem] {
        var result = [
            PaletteItem(id: "register", title: String(localized: "저장소 등록"), subtitle: "⌘O", symbol: "folder.badge.plus", keywords: "register add repository", action: .register),
            PaletteItem(id: "refresh", title: String(localized: "전체 새로고침"), subtitle: "⌘R", symbol: "arrow.clockwise", keywords: "refresh", action: .refresh),
            PaletteItem(id: "activity", title: String(localized: "실행 현황 열기"), subtitle: String(localized: "모든 저장소의 작업·터미널"), symbol: "play.rectangle", keywords: "activity running tasks", action: .activity),
        ]
        for repository in model.settings.repositories.sorted(by: { $0.name < $1.name }) {
            result.append(PaletteItem(id: "repo:\(repository.id)", title: repository.name, subtitle: repository.path,
                symbol: "folder", keywords: "repository 저장소", action: .repository(repository.id)))
        }
        for tree in model.worktrees.sorted(by: { $0.displayName < $1.displayName }) {
            let repository = model.settings.repositories.first { $0.id == tree.repositoryID }?.name ?? "—"
            let context = "\(repository) › \(tree.displayName)"
            result.append(PaletteItem(id: "tree:\(tree.id)", title: context, subtitle: tree.path,
                symbol: "arrow.triangle.branch", keywords: "worktree 워크트리 이동", action: .worktree(tree.id)))
            if tree.canExecute {
                result.append(PaletteItem(id: "shell:\(tree.id)", title: String(localized: "터미널 열기 · \(context)"), subtitle: tree.path,
                    symbol: "terminal", keywords: "shell terminal", action: .shell(tree.id)))
            }
        }
        if let tree = model.selectedWorktree {
            for group in model.settings.taskGroups where group.repositoryID == tree.repositoryID {
                let active = model.execution.groups.active(definitionID: group.id, worktreeID: tree.id, execution: model.execution)
                result.append(PaletteItem(id: "group:\(tree.id):\(group.id)",
                    title: active == nil ? String(localized: "그룹 실행 · \(group.name)") : String(localized: "그룹 중지 · \(group.name)"),
                    subtitle: tree.displayName, symbol: "square.stack.3d.up", keywords: "group 그룹 실행",
                    action: active.map { .stopGroup($0.id) } ?? .group(tree.id, group.id), enabled: tree.canExecute))
            }
            for candidate in model.candidates(for: tree) {
                let task = candidate.definition
                if let active = model.execution.activeTask(task.id, worktreeID: tree.id) {
                    result.append(PaletteItem(id: "session:\(active.id)", title: String(localized: "출력 보기 · \(task.name)"),
                        subtitle: tree.displayName, symbol: "terminal", keywords: "task 작업", action: .session(active.id)))
                } else {
                    result.append(PaletteItem(id: "task:\(tree.id):\(task.id)", title: String(localized: "작업 실행 · \(task.name)"),
                        subtitle: "\(tree.displayName) · \(task.command.display)", symbol: "play.fill", keywords: "task run 실행",
                        action: .task(tree.id, task.id), enabled: tree.canExecute && !candidate.needsPackageManager && !model.execution.isPreparing(task.id, worktreeID: tree.id)))
                }
            }
        }
        for entry in model.execution.entries where entry.session.isActive {
            for port in entry.ports {
                if let url = port.browserURL(scheme: "http") {
                    result.append(PaletteItem(id: "port:\(entry.id):\(port.id)", title: String(localized: "HTTP 열기 · \(port.port)"),
                        subtitle: entry.title + " · " + url.absoluteString, symbol: "globe", keywords: "port browser 포트 브라우저", action: .url(url)))
                }
            }
        }
        return result
    }

    static func search(_ query: String, items: [PaletteItem]) -> [PaletteItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(items.filter { item in
            let text = item.title + " " + item.subtitle + " " + item.keywords
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }.prefix(100))
    }
}

struct CommandPalette: View {
    @Bindable var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selection: String?

    private var items: [PaletteItem] { PaletteCatalog.search(query, items: PaletteCatalog.items(model: model)) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("저장소·워크트리·작업 검색", text: $query).textFieldStyle(.plain)
                    .focused($focused).onSubmit(executeSelection).accessibilityIdentifier("paletteSearch")
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            List(selection: $selection) {
                ForEach(items) { item in
                    HStack {
                        Image(systemName: item.symbol).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .opacity(item.enabled ? 1 : 0.45).tag(item.id)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { execute(item) }
                }
            }
            .onKeyPress(.return) { executeSelection(); return .handled }
            .overlay { if items.isEmpty { ContentUnavailableView("검색 결과 없음", systemImage: "magnifyingglass") } }
            Text("↑ ↓ 선택 · Return 실행 · Esc 닫기").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8).frame(width: 660, height: 480)
        .onAppear { query = ""; focused = true; selection = items.first?.id }
        .onChange(of: items.map(\.id)) { _, ids in if selection == nil || !ids.contains(selection!) { selection = ids.first } }
    }

    private func move(_ offset: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selection } ?? 0
        selection = items[min(max(index + offset, 0), items.count - 1)].id
    }

    private func executeSelection() {
        if let item = items.first(where: { $0.id == selection }) ?? items.first { execute(item) }
    }

    private func execute(_ item: PaletteItem) {
        guard item.enabled, model.isLoaded else { return }
        dismiss()
        openWindow(id: "main")
        Task {
            do {
                switch item.action {
                case .register: model.chooseRepository()
                case .refresh: await model.refreshAll()
                case .activity: model.showActivity = true; model.search = ""; model.terminalPresentation = .normal
                case .repository(let id): model.search = ""; model.worktreeFilter = .all; model.selectRepository(id); model.terminalPresentation = .normal
                case .worktree(let id), .shell(let id):
                    guard let tree = model.worktrees.first(where: { $0.id == id }) else { return }
                    model.search = ""; model.worktreeFilter = .all
                    model.selectRepository(tree.repositoryID); model.selectWorktree(id)
                    model.terminalPresentation = .normal
                    if case .shell = item.action { try await model.openTerminal(id) }
                case .task(let worktreeID, let taskID):
                    guard let tree = model.worktrees.first(where: { $0.id == worktreeID }),
                        let candidate = model.candidates(for: tree).first(where: { $0.id == taskID }), !candidate.needsPackageManager else { return }
                    try await model.runTask(candidate.definition, worktreeID: worktreeID)
                case .session(let id):
                    if let entry = model.execution.entries.first(where: { $0.id == id }) { model.revealSession(entry) }
                case .url(let url): model.openURL(url)
                case .group(let treeID, let groupID):
                    if let group = model.settings.taskGroups.first(where: { $0.id == groupID }) { try model.startGroup(group, worktreeID: treeID) }
                case .stopGroup(let id):
                    if let run = model.execution.groups.runs.first(where: { $0.id == id }) { try await model.execution.groups.stop(run, execution: model.execution) }
                }
            } catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
        }
    }
}
