import AppKit
import Observation

@MainActor
@Observable
final class DashboardModel {
    enum TerminalPresentation { case normal, hidden, maximized }
    var settings = AppSettings()
    private(set) var worktrees: [Worktree] = []
    private(set) var repositoryErrors: [UUID: String] = [:]
    private(set) var loadingRepositories: Set<UUID> = []
    private(set) var isLoaded = false
    private var registeringCount = 0
    var isRegistering: Bool { registeringCount > 0 }
    private var isLoadingSettings = false
    private var changingRepositories: Set<UUID> = []
    private var unregisteringRepositories: Set<UUID> = []
    private(set) var isTerminating = false
    private(set) var settingsError: String?
    private(set) var saveError: String?
    var errorMessage: String?
    var search = ""
    var favoritesOnly = false
    var showActivity = false
    var worktreeFilter: DashboardFilter = .all
    var terminalPresentation: TerminalPresentation = .normal
    var isAppActive = true
    var selectedRepositoryID: UUID?
    var selectedWorktreeID: UUID?
    let execution: ExecutionCoordinator
    let tasks = TaskCatalogModel()
    let git: GitService
    private let store: SettingsStore
    private var revision = 0
    private var generations: [UUID: Int] = [:]
    private var statusGenerations: [UUID: Int] = [:]
    private(set) var expandedUntracked: Set<UUID> = []

    init(store: SettingsStore = SettingsStore(), git: GitService = GitService(), execution: ExecutionCoordinator = ExecutionCoordinator()) {
        self.store = store
        self.git = git
        self.execution = execution
        execution.onWorktreeExit = { [weak self] id in Task { await self?.refreshStatus(id) } }
    }

    var selectedWorktree: Worktree? { worktrees.first { $0.id == selectedWorktreeID } }
    var selectedRepository: Repository? {
        settings.repositories.first { $0.id == (selectedRepositoryID ?? selectedWorktree?.repositoryID) }
    }

    var visibleWorktrees: [Worktree] {
        worktrees.filter { tree in
            guard let repository = settings.repositories.first(where: { $0.id == tree.repositoryID }) else { return false }
            if let selectedRepositoryID, tree.repositoryID != selectedRepositoryID { return false }
            if favoritesOnly && !repository.favorite { return false }
            switch worktreeFilter {
            case .all: break
            case .running:
                guard execution.entries(for: tree.id).contains(where: { $0.session.isActive }) || execution.pendingCount(worktreeID: tree.id) > 0
                    || execution.groups.runs.contains(where: { $0.worktreeID == tree.id && $0.isActive }) else { return false }
            case .failed: guard execution.hasFailedTask(worktreeID: tree.id) else { return false }
            case .changed: guard tree.status?.isClean == false else { return false }
            case .unavailable: guard tree.isMissing || tree.error != nil || repositoryErrors[tree.repositoryID] != nil else { return false }
            }
            return search.isEmpty || [tree.path, tree.displayName, repository.name].contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted {
            if $0.repositoryID == $1.repositoryID {
                if $0.isMain != $1.isMain { return $0.isMain }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.repositoryID.uuidString < $1.repositoryID.uuidString
        }
    }

    func load(restoreBackup: Bool = false) async {
        guard !isTerminating, !isLoadingSettings, !isRegistering, changingRepositories.isEmpty,
            !isLoaded || restoreBackup || settingsError != nil else { return }
        guard !execution.hasActiveSession else {
            errorMessage = String(localized: "설정을 다시 읽기 전에 실행 중인 세션을 정리하세요.")
            return
        }
        isLoadingSettings = true
        isLoaded = false
        defer { isLoadingSettings = false }
        do {
            let loaded = try await (restoreBackup ? store.restoreBackup() : store.load())
            for id in generations.keys { generations[id, default: 0] += 1 }
            for id in statusGenerations.keys { statusGenerations[id, default: 0] += 1 }
            for id in Set(worktrees.map(\.id) + execution.entries.map(\.worktreeID)) {
                tasks.forget(id)
                execution.discard(worktreeID: id)
            }
            worktrees.removeAll()
            repositoryErrors.removeAll()
            loadingRepositories.removeAll()
            expandedUntracked.removeAll()
            settings = loaded
            if !settings.repositories.contains(where: { $0.id == settings.selectedRepositoryID }) {
                settings.selectedRepositoryID = nil
            }
            selectedRepositoryID = settings.selectedRepositoryID
            selectedWorktreeID = settings.selectedWorktreeID
            settingsError = nil
            saveError = nil
            isLoaded = true
            await refreshAll()
        } catch {
            settingsError = error.localizedDescription
            isLoaded = false
        }
    }

    func save() async {
        guard isLoaded else { return }
        revision += 1
        let value = settings, version = revision
        do {
            try await store.save(value, revision: version)
            if revision == version { saveError = nil }
        } catch { if revision == version { saveError = error.localizedDescription } }
    }

    func reloadSettings() async {
        guard !isTerminating, !isLoadingSettings, !isRegistering, changingRepositories.isEmpty else { return }
        guard !execution.hasActiveSession else {
            errorMessage = String(localized: "설정을 다시 읽기 전에 실행 중인 세션을 정리하세요.")
            return
        }
        isLoaded = false
        saveError = nil
        await load()
    }

    func chooseRepository(reconnecting id: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = id == nil
        panel.prompt = String(localized: "등록")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                do { try await register(url, reconnecting: id) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func register(_ url: URL, reconnecting id: UUID? = nil) async throws {
        guard !isTerminating else { throw CancellationError() }
        guard isLoaded else { throw ExecutionError(message: "설정을 복구한 뒤 저장소를 등록하세요.") }
        if let id { try beginRepositoryChange(id) }
        registeringCount += 1
        defer {
            registeringCount -= 1
            if let id { changingRepositories.remove(id) }
        }
        var repository = try await git.identify(url, executable: settings.gitPath)
        if let duplicate = settings.repositories.first(where: { $0.commonDirectory == repository.commonDirectory && $0.id != id }) {
            selectRepository(duplicate.id)
            await refreshRepository(duplicate)
            return
        }
        if let id, let index = settings.repositories.firstIndex(where: { $0.id == id }) {
            let identities = settings.worktreeIdentities.filter { $0.repositoryID == id }
            guard !execution.entries.contains(where: { $0.repositoryID == id && $0.session.isActive }),
                !execution.groups.runs.contains(where: { $0.repositoryID == id && execution.groups.canStop($0, execution: execution) }),
                !identities.contains(where: { execution.pendingCount(worktreeID: $0.id) > 0 }) else {
                throw ExecutionError(message: "재연결 전에 이 저장소의 실행 세션을 중지하세요.")
            }
            let oldCommon = settings.repositories[index].commonDirectory
            for identityIndex in settings.worktreeIdentities.indices where settings.worktreeIdentities[identityIndex].repositoryID == id {
                if let directory = settings.worktreeIdentities[identityIndex].gitDirectory,
                    directory == oldCommon || directory.hasPrefix(oldCommon + "/") {
                    settings.worktreeIdentities[identityIndex].gitDirectory = repository.commonDirectory + directory.dropFirst(oldCommon.count)
                }
            }
            repository.id = id
            repository.name = settings.repositories[index].name
            repository.favorite = settings.repositories[index].favorite
            settings.repositories[index] = repository
        } else { settings.repositories.append(repository) }
        selectRepository(repository.id)
        await save()
        await refreshRepository(repository, force: true)
        if let first = visibleWorktrees.first { selectWorktree(first.id) }
    }

    func selectRepository(_ id: UUID?, favorites: Bool = false) {
        showActivity = false
        selectedRepositoryID = id
        favoritesOnly = favorites
        settings.selectedRepositoryID = id
        if let current = selectedWorktree, (id != nil && current.repositoryID != id) {
            selectedWorktreeID = nil
            settings.selectedWorktreeID = nil
        }
        Task { await save() }
    }

    func selectWorktree(_ id: UUID?) {
        selectedWorktreeID = id
        settings.selectedWorktreeID = id
        Task {
            await save()
            guard let id else { return }
            await refreshStatus(id)
            if let tree = worktrees.first(where: { $0.id == id }) { await detect(tree) }
        }
    }

    func toggleFavorite(_ repository: Repository) {
        guard let index = settings.repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        settings.repositories[index].favorite.toggle()
        Task { await save() }
    }

    func renameRepository(_ id: UUID, name: String) async {
        guard let index = settings.repositories.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        settings.repositories[index].name = name
        await save()
    }

    func unregister(_ repository: Repository) async throws {
        try beginRepositoryChange(repository.id)
        unregisteringRepositories.insert(repository.id)
        generations[repository.id, default: 0] += 1
        loadingRepositories.remove(repository.id)
        defer {
            changingRepositories.remove(repository.id)
            unregisteringRepositories.remove(repository.id)
        }
        let ids = Array(Set(worktrees.filter { $0.repositoryID == repository.id }.map(\.id)
            + execution.entries.filter { $0.repositoryID == repository.id }.map(\.worktreeID)
            + settings.worktreeIdentities.filter { $0.repositoryID == repository.id }.map(\.id)))
        execution.blockedWorktrees.formUnion(ids)
        defer { execution.blockedWorktrees.subtract(ids) }
        for id in ids { try await execution.stop(worktreeID: id); execution.discard(worktreeID: id) }
        ids.forEach(tasks.forget)
        expandedUntracked.subtract(ids)
        for id in ids { statusGenerations[id, default: 0] += 1 }
        settings.repositories.removeAll { $0.id == repository.id }
        settings.worktreeIdentities.removeAll { $0.repositoryID == repository.id }
        settings.taskRules.removeAll { $0.repositoryID == repository.id }
        settings.taskGroups.removeAll { $0.repositoryID == repository.id }
        settings.taskPreferences.removeAll { ids.contains($0.worktreeID) }
        worktrees.removeAll { $0.repositoryID == repository.id }
        repositoryErrors.removeValue(forKey: repository.id)
        if selectedRepositoryID == repository.id { selectRepository(nil) }
        if let selectedWorktreeID, ids.contains(selectedWorktreeID) { selectWorktree(nil) }
        await save()
    }

    func refreshAll() async {
        let repositories = settings.repositories
        await withTaskGroup(of: Void.self) { group in
            for repository in repositories { group.addTask { await self.refreshRepository(repository) } }
        }
        if selectedWorktreeID != nil, selectedWorktree == nil, loadingRepositories.isEmpty {
            selectWorktree(visibleWorktrees.first?.id)
        }
        if let tree = selectedWorktree { await detect(tree) }
    }

    func refreshRepository(_ repository: Repository, force: Bool = false) async {
        guard isLoaded, !isTerminating, !unregisteringRepositories.contains(repository.id),
            settings.repositories.first(where: { $0.id == repository.id })?.commonDirectory == repository.commonDirectory else { return }
        if loadingRepositories.contains(repository.id) && !force { return }
        let generation = (generations[repository.id] ?? 0) + 1
        generations[repository.id] = generation
        loadingRepositories.insert(repository.id)
        defer { if generations[repository.id] == generation { loadingRepositories.remove(repository.id) } }
        let executable = settings.gitPath
        do {
            var trees = try await git.worktrees(repository, executable: executable)
            guard generations[repository.id] == generation,
                settings.repositories.first(where: { $0.id == repository.id })?.commonDirectory == repository.commonDirectory else { return }
            var identitiesChanged = false
            var matchedIdentities: Set<UUID> = []
            for index in trees.indices {
                let item = trees[index]
                // Metadata identifies a worktree even when another tree reuses its old path.
                let identityIndex = settings.worktreeIdentities.firstIndex {
                    $0.repositoryID == repository.id && !matchedIdentities.contains($0.id)
                        && item.gitDirectory != nil && $0.gitDirectory == item.gitDirectory
                } ?? settings.worktreeIdentities.firstIndex {
                    $0.repositoryID == repository.id && !matchedIdentities.contains($0.id) && $0.path == item.path
                        && ($0.gitDirectory == nil || item.gitDirectory == nil)
                }
                if let identityIndex {
                    trees[index].id = settings.worktreeIdentities[identityIndex].id
                    matchedIdentities.insert(trees[index].id)
                    if settings.worktreeIdentities[identityIndex].path != item.path ||
                        (item.gitDirectory != nil && settings.worktreeIdentities[identityIndex].gitDirectory != item.gitDirectory) {
                        settings.worktreeIdentities[identityIndex].path = item.path
                        if let directory = item.gitDirectory { settings.worktreeIdentities[identityIndex].gitDirectory = directory }
                        identitiesChanged = true
                    }
                }
                else {
                    settings.worktreeIdentities.append(WorktreeIdentity(id: item.id, repositoryID: repository.id,
                        path: item.path, gitDirectory: item.gitDirectory))
                    identitiesChanged = true
                }
                if let previous = worktrees.first(where: { $0.id == trees[index].id }) { trees[index].status = previous.status }
            }
            for var previous in worktrees where previous.repositoryID == repository.id && !trees.contains(where: { $0.id == previous.id }) {
                if !execution.entries(for: previous.id).isEmpty {
                    previous.isMissing = true
                    previous.error = String(localized: "Git 목록에서 제거되었습니다. 열린 세션과 출력을 확인하고 정리하세요.")
                    statusGenerations[previous.id, default: 0] += 1
                    trees.append(previous)
                }
            }
            worktrees.removeAll { $0.repositoryID == repository.id }
            worktrees.append(contentsOf: trees)
            if let selectedWorktreeID, !worktrees.contains(where: { $0.id == selectedWorktreeID }),
                settings.worktreeIdentities.contains(where: { $0.id == selectedWorktreeID && $0.repositoryID == repository.id }) {
                selectWorktree(nil)
            }
            repositoryErrors.removeValue(forKey: repository.id)
            if identitiesChanged { await save() }
            await withTaskGroup(of: Void.self) { group in
                for tree in trees where tree.canExecute { group.addTask { await self.refreshStatus(tree.id) } }
            }
            if selectedWorktreeID == nil, let first = visibleWorktrees.first { selectWorktree(first.id) }
        } catch {
            guard generations[repository.id] == generation,
                settings.repositories.first(where: { $0.id == repository.id })?.commonDirectory == repository.commonDirectory else { return }
            repositoryErrors[repository.id] = error.localizedDescription
        }
    }

    func refreshStatus(_ id: UUID, expandUntracked: Bool? = nil) async {
        if let expandUntracked {
            if expandUntracked { expandedUntracked.insert(id) }
            else { expandedUntracked.remove(id) }
        }
        guard isLoaded, !isTerminating, let tree = worktrees.first(where: { $0.id == id }), tree.canExecute,
            !unregisteringRepositories.contains(tree.repositoryID) else { return }
        let generation = (statusGenerations[id] ?? 0) + 1
        statusGenerations[id] = generation
        do {
            let status = try await git.status(path: tree.path, executable: settings.gitPath, expandUntracked: expandedUntracked.contains(id))
            guard statusGenerations[id] == generation, let index = worktrees.firstIndex(where: { $0.id == id && $0.path == tree.path }) else { return }
            worktrees[index].status = status
            worktrees[index].branchRef = status.branch.map { "refs/heads/\($0)" }
            worktrees[index].head = status.head
            worktrees[index].error = nil
        } catch {
            guard statusGenerations[id] == generation, let index = worktrees.firstIndex(where: { $0.id == id && $0.path == tree.path }) else { return }
            worktrees[index].error = error.localizedDescription
        }
    }

    func poll() async {
        var tick = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard isLoaded, isAppActive, !isTerminating else { continue }
            tick += 1
            if tick % 30 == 0 { await refreshAll() }
            else if tick % 10 == 0 {
                await refreshVisibleRepositories()
            } else if tick % 3 == 0, let id = selectedWorktreeID { await refreshStatus(id) }
        }
    }

    var visibleRepositoryIDs: Set<UUID> {
        if showActivity { return Set(settings.repositories.map(\.id)) }
        var ids = Set(visibleWorktrees.map(\.repositoryID))
        for repository in settings.repositories where selectedRepositoryID == nil || selectedRepositoryID == repository.id {
            if favoritesOnly && !repository.favorite { continue }
            if !worktrees.contains(where: { $0.repositoryID == repository.id }) { ids.insert(repository.id) }
        }
        return ids
    }

    func revealSession(_ entry: SessionEntry, stayInActivity: Bool = false) {
        guard worktrees.contains(where: { $0.id == entry.worktreeID }) else {
            errorMessage = String(localized: "워크트리를 찾을 수 없습니다. 저장소를 새로고침하세요.")
            return
        }
        search = ""
        worktreeFilter = .all
        selectRepository(entry.repositoryID)
        selectWorktree(entry.worktreeID)
        execution.selectedSessions[entry.worktreeID] = entry.id
        showActivity = stayInActivity
        terminalPresentation = .normal
    }

    func refreshVisibleRepositories() async {
        let ids = visibleRepositoryIDs
        await withTaskGroup(of: Void.self) { group in
            for repository in settings.repositories where ids.contains(repository.id) {
                group.addTask { await self.refreshRepository(repository) }
            }
        }
    }

    func detect(_ worktree: Worktree) async {
        guard !isTerminating else { return }
        await tasks.refresh(worktree: worktree, preferences: settings.taskPreferences.first { $0.worktreeID == worktree.id })
    }

    func candidates(for tree: Worktree) -> [TaskCandidate] {
        TaskCatalog.merge(tasks.reports[tree.id] ?? DetectionReport(), rules: settings.taskRules,
                          repositoryID: tree.repositoryID, worktreeID: tree.id)
    }

    func runTask(_ definition: TaskDefinition, worktreeID: UUID, restarting entry: SessionEntry? = nil) async throws {
        guard isLoaded, !isTerminating, let tree = worktrees.first(where: { $0.id == worktreeID }),
            !execution.blockedWorktrees.contains(worktreeID) else { throw CancellationError() }
        try await execution.run(definition, worktree: tree, shell: settings.shellPath, restarting: entry)
        if selectedWorktreeID == worktreeID && terminalPresentation == .hidden { terminalPresentation = .normal }
    }

    func openTerminal(_ worktreeID: UUID) async throws {
        guard isLoaded, !isTerminating, let tree = worktrees.first(where: { $0.id == worktreeID }),
            !execution.blockedWorktrees.contains(worktreeID) else { throw CancellationError() }
        if terminalPresentation == .hidden { terminalPresentation = .normal }
        try await execution.openShell(worktree: tree, shell: settings.shellPath)
    }

    func saveTask(_ definition: TaskDefinition, tree: Worktree, shared: Bool, hidden: Bool = false) async {
        let worktreeID = shared ? nil : tree.id
        settings.taskRules.removeAll {
            $0.repositoryID == tree.repositoryID && $0.definition.id == definition.id
                && ($0.worktreeID == worktreeID || (shared && $0.worktreeID == tree.id))
        }
        settings.taskRules.append(TaskRule(repositoryID: tree.repositoryID, worktreeID: worktreeID, definition: definition, hidden: hidden))
        await save()
    }

    func resetTask(_ definition: TaskDefinition, tree: Worktree) async {
        let hasOverride = settings.taskRules.contains { $0.worktreeID == tree.id && $0.definition.id == definition.id }
        settings.taskRules.removeAll { $0.repositoryID == tree.repositoryID && $0.worktreeID == (hasOverride ? tree.id : nil) && $0.definition.id == definition.id }
        await save()
    }

    func setTaskPreferences(_ preferences: WorktreeTaskPreferences, tree: Worktree) async {
        settings.taskPreferences.removeAll { $0.worktreeID == tree.id }
        settings.taskPreferences.append(preferences)
        await save()
        await detect(tree)
    }

    func createWorktree(repository: Repository, branch: String, startPoint: String, path: String, existing: Bool) async throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw ExecutionError(message: "워크트리 경로는 절대 경로여야 합니다.")
        }
        try beginRepositoryChange(repository.id)
        defer { changingRepositories.remove(repository.id) }
        do {
            try await git.create(repository: repository, branch: branch, startPoint: startPoint,
                destination: URL(fileURLWithPath: path), existing: existing, executable: settings.gitPath)
        } catch {
            await refreshRepository(repository, force: true)
            throw error
        }
        await refreshRepository(repository, force: true)
        let trees = worktrees
        let createdID = await Task.detached(priority: .userInitiated) {
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return trees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == canonical }?.id
        }.value
        if let createdID {
            selectWorktree(createdID)
        }
    }

    func removeWorktree(_ tree: Worktree) async throws {
        guard let repository = settings.repositories.first(where: { $0.id == tree.repositoryID }) else { return }
        try beginRepositoryChange(repository.id)
        defer { changingRepositories.remove(repository.id) }
        // Revalidate before stopping sessions as the sheet may describe an old path.
        _ = try await git.removalPreview(repository: repository, worktree: tree, executable: settings.gitPath)
        execution.blockedWorktrees.insert(tree.id)
        defer { execution.blockedWorktrees.remove(tree.id) }
        try await execution.stop(worktreeID: tree.id)
        do { try await git.remove(repository: repository, worktree: tree, executable: settings.gitPath) }
        catch { await refreshRepository(repository, force: true); throw error }
        execution.discard(worktreeID: tree.id)
        tasks.forget(tree.id)
        expandedUntracked.remove(tree.id)
        settings.worktreeIdentities.removeAll { $0.id == tree.id }
        settings.taskPreferences.removeAll { $0.worktreeID == tree.id }
        settings.taskRules.removeAll { $0.worktreeID == tree.id }
        if selectedWorktreeID == tree.id { selectWorktree(nil) }
        await save()
        await refreshRepository(repository, force: true)
    }

    private func beginRepositoryChange(_ id: UUID) throws {
        guard isLoaded, !isTerminating, settings.repositories.contains(where: { $0.id == id }) else { throw CancellationError() }
        guard changingRepositories.insert(id).inserted else {
            throw ExecutionError(message: "저장소 변경 작업이 진행 중입니다. 완료 후 다시 시도하세요.")
        }
    }

    func prepareForTermination() async {
        isTerminating = true
        // Finish accepted mutations before the final settings snapshot. Read-only
        // polling can then be cancelled without abandoning a worktree creation.
        while isLoadingSettings || isRegistering || !changingRepositories.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await git.suspend()
    }

    func cancelTermination() async {
        await git.resume()
        isTerminating = false
    }

    func reveal(_ tree: Worktree) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tree.path) }
    func copyPath(_ path: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }

    func openEditor(_ tree: Worktree) {
        let editor = URL(fileURLWithPath: settings.editorPath)
        NSWorkspace.shared.open([URL(fileURLWithPath: tree.path)], withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
            }
    }

    func chooseTaskDirectory(_ tree: Worktree) async throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: tree.path)
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        return try await Task.detached {
            let root = URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().standardizedFileURL.path
            let path = selected.resolvingSymlinksInPath().standardizedFileURL.path
            if path == root { return "." }
            guard path.hasPrefix(root + "/") else { throw ExecutionError(message: "워크트리 안의 폴더를 선택하세요.") }
            return String(path.dropFirst(root.count + 1))
        }.value
    }

    func openURL(_ url: URL) {
        guard ["http", "https"].contains(url.scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}
