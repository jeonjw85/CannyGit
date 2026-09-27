import AppKit
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct TaskGroupTests {
    private func setup() throws -> (URL, Worktree, ExecutionCoordinator) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-groups-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tree = Worktree(repositoryID: UUID(), path: root.path, gitDirectory: root.path)
        let execution = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path])
        return (root, tree, execution)
    }

    private func definition(tree: Worktree, plan: [[TaskDefinition]]) -> TaskGroupDefinition {
        TaskGroupDefinition(repositoryID: tree.repositoryID, name: "Group",
            stages: plan.map { TaskGroupStage(taskIDs: $0.map(\.id)) },
            references: plan.flatMap { $0 }.map { GroupTaskReference(id: $0.id, name: $0.name, directory: $0.directory) })
    }

    @Test func stagesWaitForSuccessfulParallelTasks() async throws {
        let (root, tree, execution) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = TaskDefinition(name: "A", command: .shell("printf ready > a; for i in {1..150}; do [[ -f b ]] && break; /bin/sleep .02; done; [[ -f b ]] || exit 8; printf done > a"))
        let b = TaskDefinition(name: "B", command: .shell("printf ready > b; for i in {1..150}; do [[ -f a ]] && break; /bin/sleep .02; done; [[ -f a ]] || exit 8; printf done > b"))
        let c = TaskDefinition(name: "C", command: .shell("[[ $(<a) == done && $(<b) == done ]] || exit 9; printf complete > c"))
        let plan = [[a, b], [c]], definition = definition(tree: tree, plan: [[a, b], [c]])
        let run = try execution.groups.start(definition: definition, worktree: tree, shell: "/bin/zsh", execution: execution) { plan }
        do {
            try await until { !run.isActive }
            #expect(run.status == .succeeded)
            #expect(try String(contentsOf: root.appendingPathComponent("c"), encoding: .utf8) == "complete")
            #expect(run.memberIDs.count == 3)
            let ends = execution.entries.filter { $0.task?.id != c.id }.compactMap(\.endedAt)
            let firstEnd = try #require(ends.max())
            let secondStart = try #require(execution.entries.first { $0.task?.id == c.id }?.startedAt)
            #expect(secondStart >= firstEnd)
        } catch { _ = await execution.prepareToQuit(); throw error }
    }

    @Test func failureStopsOnlyTheGroupsSessionsAndBlocksLaterStages() async throws {
        let (root, tree, execution) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = TaskDefinition(name: "independent", command: .executable("/bin/sleep", ["30"]), kind: .server)
        let independent = try await execution.run(external, worktree: tree, shell: "/bin/zsh")
        let fail = TaskDefinition(name: "fail", command: .shell("exit 7"))
        let server = TaskDefinition(name: "owned", command: .executable("/bin/sleep", ["30"]), kind: .server)
        let plan = [[fail, server]]
        let run = try execution.groups.start(definition: definition(tree: tree, plan: plan), worktree: tree, shell: "/bin/zsh", execution: execution) { plan }
        do {
            try await until { !run.isActive }
            #expect(run.status == .failed)
            #expect(independent.session.isActive)
            #expect(execution.entries.filter { $0.groupRunID == run.id }.allSatisfy { !$0.session.isActive })
            let later = TaskDefinition(name: "must not run", command: .shell("touch unexpected"))
            let sequence = [[fail], [later]]
            let stopped = try execution.groups.start(definition: definition(tree: tree, plan: sequence), worktree: tree, shell: "/bin/zsh", execution: execution) { sequence }
            try await until { !stopped.isActive }
            #expect(stopped.status == .failed)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
            #expect(independent.session.isActive)
            #expect(await execution.prepareToQuit())
        } catch { _ = await execution.prepareToQuit(); throw error }
    }

    @Test func cancelDuringResolutionAndQuitPreventLateLaunches() async throws {
        actor Gate {
            var entered = false
            var waiter: CheckedContinuation<Void, Never>?
            func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
            func release() { waiter?.resume(); waiter = nil }
        }
        let (root, tree, execution) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = TaskDefinition(name: "late", command: .shell("touch unexpected"))
        let definition = definition(tree: tree, plan: [[task]])
        let gate = Gate()
        let run = try execution.groups.start(definition: definition, worktree: tree, shell: "/bin/zsh", execution: execution) {
            await gate.wait()
            return [[task]]
        }
        while await !gate.entered { await Task.yield() }
        #expect(throws: (any Error).self) {
            try execution.groups.start(definition: definition, worktree: tree, shell: "/bin/zsh", execution: execution) { [[task]] }
        }
        #expect(await execution.prepareToQuit())
        await gate.release()
        await execution.groups.waitForSettlement(run.id)
        #expect(run.status == .stopped)
        #expect(execution.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }

    @Test func cancelledGroupDoesNotCancelANewerIndependentPreparation() async throws {
        actor Preparation: TaskLaunchPreparing {
            var calls = 0
            var waiter: CheckedContinuation<Void, Never>?
            func configuration(task: TaskDefinition, root: URL, shell: String, environment: [String: String]) async throws -> TerminalLaunch {
                calls += 1
                if calls == 2 { await withCheckedContinuation { waiter = $0 } }
                return try await TaskLauncher().configuration(task: task, root: root, shell: shell, environment: environment)
            }
            func release() { waiter?.resume(); waiter = nil }
        }
        let (root, tree, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let preparation = Preparation()
        let execution = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path], launcher: preparation)
        let task = TaskDefinition(name: "server", command: .executable("/bin/sleep", ["30"]), kind: .server)
        let plan = [[task]]
        let run = try execution.groups.start(definition: definition(tree: tree, plan: plan), worktree: tree, shell: "/bin/zsh", execution: execution) { plan }
        while await preparation.calls < 2 { await Task.yield() }
        try await execution.groups.stop(run, execution: execution)
        do {
            let independent = try await execution.run(task, worktree: tree, shell: "/bin/zsh")
            await preparation.release()
            await execution.groups.waitForSettlement(run.id)
            #expect(run.memberIDs.isEmpty && run.status == .stopped)
            #expect(independent.session.isActive && independent.groupRunID == nil)
            #expect(await execution.prepareToQuit())
        } catch { await preparation.release(); _ = await execution.prepareToQuit(); throw error }
    }

    @Test func groupSettingsMigrateAndServerStagesAreValidated() async throws {
        let (root, tree, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"repositories":[]}"#.utf8).write(to: url)
        let store = SettingsStore(url: url)
        var settings = try await store.load()
        #expect(settings.schemaVersion == 2 && settings.taskGroups.isEmpty)
        let server = TaskDefinition(name: "server", command: .shell("sleep 10"), kind: .server)
        let once = TaskDefinition(name: "test", command: .shell("exit 0"))
        let invalid = definition(tree: tree, plan: [[server], [once]])
        #expect(throws: (any Error).self) { try invalid.validatePlan([[server], [once]]) }
        let valid = definition(tree: tree, plan: [[once], [server]])
        try valid.validatePlan([[once], [server]])
        settings.taskGroups = [valid]
        try await store.save(settings, revision: 1)
        #expect(try await SettingsStore(url: url).load().taskGroups == [valid])
    }

    @Test func savedGroupUsesCurrentWorktreeOverrideAndRejectsExistingRuns() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service,
            execution: ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "ZDOTDIR": fixture.root.path]))
        await model.load()
        try await model.register(fixture.path)
        let tree = try #require(model.worktrees.first)
        let oldDirectory = fixture.path.appendingPathComponent("old")
        let newDirectory = fixture.path.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        var task = TaskDefinition(name: "current", command: .shell("printf shared > result"), directory: "old")
        await model.saveTask(task, tree: tree, shared: true)
        let definition = definition(tree: tree, plan: [[task]])
        try await model.saveGroup(definition, tree: tree)
        task.command = .shell("printf override > result")
        task.directory = "new"
        await model.saveTask(task, tree: tree, shared: false)
        try FileManager.default.removeItem(at: oldDirectory)
        let run = try model.startGroup(definition, worktreeID: tree.id)
        do {
            try await until { !run.isActive }
            #expect(run.status == .succeeded)
            #expect(try String(contentsOf: newDirectory.appendingPathComponent("result"), encoding: .utf8) == "override")
            task.command = .executable("/bin/sleep", ["30"])
            let independent = try await model.execution.run(task, worktree: tree, shell: "/bin/zsh")
            let rejected = try model.startGroup(definition, worktreeID: tree.id)
            try await until { !rejected.isActive }
            #expect(rejected.status == .failed && rejected.memberIDs.isEmpty)
            #expect(independent.session.isActive)
            #expect(await model.execution.prepareToQuit())
        } catch { _ = await model.execution.prepareToQuit(); throw error }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExecutionError(message: "그룹 검증 시간 초과") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
