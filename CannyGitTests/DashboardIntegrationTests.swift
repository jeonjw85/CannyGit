import AppKit
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct DashboardIntegrationTests {
    @Test func registrationPersistenceAndWorktreeLifecycle() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let storeURL = fixture.root.appendingPathComponent("settings.json")
        let model = DashboardModel(store: SettingsStore(url: storeURL), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let repository = try #require(model.settings.repositories.first)
        let mainID = try #require(model.worktrees.first?.id)
        let path = fixture.root.appendingPathComponent("linked tree")
        try await model.createWorktree(repository: repository, branch: "feature/integration", startPoint: "refs/heads/main", path: path.path, existing: false)
        try await model.register(path)
        #expect(model.settings.repositories.count == 1)
        #expect(model.worktrees.count == 2)
        let linked = try #require(model.worktrees.first { !$0.isMain })
        model.selectWorktree(linked.id)
        let task = TaskDefinition(name: "test", command: .shell("exit 0"))
        await model.saveTask(task, tree: linked, shared: false)
        await model.save()
        let reopened = DashboardModel(store: SettingsStore(url: storeURL), git: fixture.service)
        await reopened.load()
        #expect(reopened.worktrees.first { $0.isMain }?.id == mainID)
        #expect(reopened.worktrees.first { !$0.isMain }?.id == linked.id)
        #expect(reopened.settings.taskRules.first?.definition == task)
        #expect(reopened.execution.entries.isEmpty)
        try await reopened.removeWorktree(linked)
        #expect(reopened.worktrees.count == 1)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(reopened.settings.taskRules.isEmpty)
    }

    @Test func tasksStayWithTheirWorktreeAndDuplicateRunsAreRejected() async throws {
        _ = NSApplication.shared
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
        let secondPath = fixture.root.appendingPathComponent("second")
        try await fixture.service.create(repository: repository, branch: "second", startPoint: "refs/heads/main", destination: secondPath, existing: false, executable: fixture.executable)
        let trees = try await fixture.service.worktrees(repository, executable: fixture.executable)
        let coordinator = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "ZDOTDIR": fixture.root.path])
        let task = TaskDefinition(name: "long", command: .executable("/bin/sleep", ["30"]))
        do {
            try await coordinator.run(task, worktree: trees[0], shell: "/bin/zsh")
            try await coordinator.run(task, worktree: trees[1], shell: "/bin/zsh")
            #expect(coordinator.entries.count == 2)
            #expect(coordinator.entries[0].session.pid != coordinator.entries[1].session.pid)
            #expect(coordinator.entries[0].session.configuration.directory.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: trees[0].path).resolvingSymlinksInPath().path)
            #expect(coordinator.entries[1].session.configuration.directory.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: trees[1].path).resolvingSymlinksInPath().path)
            await #expect(throws: (any Error).self) { try await coordinator.run(task, worktree: trees[0], shell: "/bin/zsh") }
            #expect(await coordinator.prepareToQuit())
            #expect(coordinator.entries.allSatisfy { !$0.session.isActive })
        } catch { _ = await coordinator.prepareToQuit(); throw error }
    }

    @Test func typedCommandArgumentsAreNotShellSource() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-argv-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = "한글 ; $(touch should-not-exist) ' \" \n🙂"
        let definition = TaskDefinition(name: "argv", command: .executable("/usr/bin/python3", ["-c", "import sys; print(repr(sys.argv[1]))", literal]))
        let launch = try await TaskLauncher().configuration(task: definition, root: root, shell: "/bin/zsh",
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path])
        let session = TerminalSession(configuration: launch)
        await session.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.isActive && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if session.isActive { try await session.stop() }
        #expect(session.exit == .code(0))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
        #expect(String(decoding: session.output.data, as: UTF8.self).contains("$(touch should-not-exist)"))
    }

    @Test func reconnectPreservesWorktreeIdentityAndOverrides() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let repository = try #require(model.settings.repositories.first)
        let original = try #require(model.worktrees.first)
        let definition = TaskDefinition(name: "custom", command: .shell("exit 0"))
        await model.saveTask(definition, tree: original, shared: false)
        let moved = fixture.root.appendingPathComponent("moved repository")
        try FileManager.default.moveItem(at: fixture.path, to: moved)
        try await model.register(moved, reconnecting: repository.id)
        #expect(model.settings.repositories.count == 1)
        #expect(model.worktrees.first?.id == original.id)
        #expect(model.candidates(for: try #require(model.worktrees.first)).contains { $0.definition == definition })
    }

    @Test func cancelledPreparationCannotLaunchAfterCleanupOrCancelANewerRun() async throws {
        actor PausedPreparation: TaskLaunchPreparing {
            var entered = 0
            var waiters: [CheckedContinuation<Void, Never>] = []
            func configuration(task: TaskDefinition, root: URL, shell: String, environment: [String: String]) async throws -> TerminalLaunch {
                entered += 1
                await withCheckedContinuation { waiters.append($0) }
                return try await TaskLauncher().configuration(task: task, root: root, shell: shell, environment: environment)
            }
            func resumeFirst() { waiters.removeFirst().resume() }
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
        let preparation = PausedPreparation()
        let coordinator = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path], launcher: preparation)
        let tree = Worktree(repositoryID: UUID(), path: root.path, gitDirectory: root.path)
        let definition = TaskDefinition(name: "pending", command: .executable("/bin/sleep", ["30"]))
        let old = Task { try await coordinator.run(definition, worktree: tree, shell: "/bin/zsh") }
        while await preparation.entered < 1 { await Task.yield() }
        try await coordinator.stop(worktreeID: tree.id)
        let new = Task { try await coordinator.run(definition, worktree: tree, shell: "/bin/zsh") }
        while await preparation.entered < 2 { await Task.yield() }
        await preparation.resumeFirst()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(coordinator.isPreparing(definition.id, worktreeID: tree.id))
        await preparation.resumeFirst()
        do {
            _ = try await new.value
            #expect(coordinator.entries.count == 1)
            #expect(await coordinator.prepareToQuit())
        } catch { _ = await coordinator.prepareToQuit(); throw error }
    }

    @Test(.enabled(if: !installedPackageManagers().isEmpty))
    func detectedScriptsRunWithInstalledPackageManagers() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-managers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"name":"canny-fixture","version":"1.0.0","private":true,"scripts":{"probe;literal":"printf CANNY_SCRIPT_OK"}}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let env = ["PATH": packageManagerSearchPaths().joined(separator: ":"), "HOME": root.path,
                   "ZDOTDIR": root.path, "COREPACK_ENABLE_NETWORK": "0", "YARN_ENABLE_NETWORK": "0",
                   "npm_config_offline": "true", "npm_config_userconfig": "/dev/null", "NO_UPDATE_NOTIFIER": "1"]
        for manager in installedPackageManagers() {
            let report = try await TaskDetector().detect(root: root, directory: ".", preferredManager: manager)
            let task = try #require(report.candidates.first { $0.definition.name == "probe;literal" }?.definition)
            let launch = try await TaskLauncher().configuration(task: task, root: root, shell: "/bin/zsh", environment: env)
            let session = TerminalSession(configuration: launch)
            await session.start()
            let deadline = ContinuousClock.now + .seconds(10)
            while session.isActive && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            if session.isActive { try await session.stop() }
            let output = String(decoding: session.output.data, as: UTF8.self)
            #expect(session.exit == .code(0), "\(manager): \(output)")
            #expect(output.contains("CANNY_SCRIPT_OK"), "\(manager): \(output)")
        }
    }
}

private func installedPackageManagers() -> [String] {
    let paths = packageManagerSearchPaths()
    return ["npm", "pnpm", "yarn", "bun"].filter { name in
        paths.contains { FileManager.default.isExecutableFile(atPath: String($0) + "/" + name) }
    }
}

private func packageManagerSearchPaths() -> [String] {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin").path]
}
