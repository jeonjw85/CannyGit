import Foundation
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct RefinementRegressionTests {
    @Test func promotingAnOverrideReplacesOnlyTheCurrentOverride() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let repository = try #require(model.settings.repositories.first)
        try await model.createWorktree(repository: repository, branch: "other", startPoint: "refs/heads/main",
            path: fixture.root.appendingPathComponent("other").path, existing: false)
        let first = try #require(model.worktrees.first { $0.isMain })
        let second = try #require(model.worktrees.first { !$0.isMain })
        var task = TaskDefinition(name: "run", command: .shell("echo original"))
        await model.saveTask(task, tree: first, shared: false)
        var other = task
        other.command = .shell("echo other")
        await model.saveTask(other, tree: second, shared: false)
        task.command = .shell("echo shared")
        await model.saveTask(task, tree: first, shared: true)
        #expect(!model.settings.taskRules.contains { $0.worktreeID == first.id && $0.definition.id == task.id })
        #expect(model.candidates(for: first).first { $0.id == task.id }?.definition.command == task.command)
        #expect(model.candidates(for: second).first { $0.id == task.id }?.definition.command == other.command)
    }

    @Test func untrackedExpansionSurvivesRefreshes() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let id = try #require(model.worktrees.first?.id)
        let directory = fixture.path.appendingPathComponent("new-files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("b.txt"))
        await model.refreshStatus(id, expandUntracked: true)
        await model.refreshStatus(id)
        #expect(model.worktrees.first?.status?.untracked == 2)
        #expect(model.expandedUntracked.contains(id))
        await model.refreshStatus(id, expandUntracked: false)
        #expect(model.worktrees.first?.status?.untracked == 1)
    }

    @Test func allVisibleRepositoriesRefreshEvenWhenOneWorktreeIsSelected() async throws {
        let first = try await RepositoryFixture.create(), second = try await RepositoryFixture.create()
        defer { first.cleanUp(); second.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: first.root.appendingPathComponent("settings.json")), git: first.service)
        await model.load()
        try await model.register(first.path)
        try await model.register(second.path)
        await model.refreshAll()
        let firstRepository = try #require(model.settings.repositories.first)
        model.selectRepository(nil)
        model.selectedWorktreeID = model.worktrees.first { $0.repositoryID == firstRepository.id }?.id
        #expect(model.visibleRepositoryIDs.count == 2)
        try Data("changed".utf8).write(to: second.path.appendingPathComponent("new.txt"))
        await model.refreshVisibleRepositories()
        #expect(model.worktrees.first { $0.repositoryID != firstRepository.id }?.status?.untracked == 1)
        model.worktreeFilter = .changed
        #expect(model.visibleWorktrees.count == 1)
        model.worktreeFilter = .running
        #expect(model.visibleWorktrees.isEmpty)
        model.worktreeFilter = .all
        let items = PaletteCatalog.items(model: model)
        let filtered = PaletteCatalog.search("worktree main", items: items)
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { item in if case .worktree = item.action { true } else { false } })
    }
}
