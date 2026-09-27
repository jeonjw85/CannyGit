import AppKit
import Darwin
import Foundation
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct ReviewRegressionTests {
    @Test func movedWorktreesKeepTheirIdentityWhenPathsAreReused() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let repository = try #require(model.settings.repositories.first)
        let a = fixture.root.appendingPathComponent("a"), b = fixture.root.appendingPathComponent("b")
        let temporary = fixture.root.appendingPathComponent("moving")
        for (branch, path) in [("a", a), ("b", b)] {
            try await model.createWorktree(repository: repository, branch: branch, startPoint: "refs/heads/main", path: path.path, existing: false)
        }
        let originalA = try #require(model.worktrees.first { $0.branchRef == "refs/heads/a" })
        let originalB = try #require(model.worktrees.first { $0.branchRef == "refs/heads/b" })
        let custom = TaskDefinition(name: "A-only", command: .shell("exit 0"))
        await model.saveTask(custom, tree: originalA, shared: false)
        _ = try await fixture.git(["-C", fixture.path.path, "worktree", "move", a.path, temporary.path])
        _ = try await fixture.git(["-C", fixture.path.path, "worktree", "move", b.path, a.path])
        _ = try await fixture.git(["-C", fixture.path.path, "worktree", "move", temporary.path, b.path])
        await #expect(throws: (any Error).self) {
            try await model.removeWorktree(originalA)
        }
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        await model.refreshRepository(repository, force: true)
        let movedA = try #require(model.worktrees.first { $0.branchRef == "refs/heads/a" })
        let movedB = try #require(model.worktrees.first { $0.branchRef == "refs/heads/b" })
        #expect(movedA.id == originalA.id)
        #expect(movedB.id == originalB.id)
        #expect(model.candidates(for: movedA).contains { $0.id == custom.id })
        #expect(!model.candidates(for: movedB).contains { $0.id == custom.id })
    }

    @Test func reloadDropsOldWorktreesAndPaletteActions() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let url = fixture.root.appendingPathComponent("settings.json")
        let model = DashboardModel(store: SettingsStore(url: url), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        // Let selection-triggered saves settle before simulating an external settings edit.
        await model.refreshAll()
        await model.save()
        try JSONEncoder().encode(AppSettings()).write(to: url, options: .atomic)
        await model.reloadSettings()
        #expect(model.isLoaded && model.settings.repositories.isEmpty)
        #expect(model.worktrees.isEmpty && model.tasks.reports.isEmpty)
        #expect(!PaletteCatalog.items(model: model).contains {
            switch $0.action { case .worktree, .shell, .task: true; default: false }
        })
    }

    @Test func unregisterInvalidatesAnInFlightRefresh() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let repository = try #require(model.settings.repositories.first)
        let wrapper = fixture.root.appendingPathComponent("slow-git")
        try Data("#!/bin/sh\n/bin/sleep .3\nexec /usr/bin/git \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        model.settings.gitPath = wrapper.path
        let refresh = Task { await model.refreshRepository(repository, force: true) }
        while !model.loadingRepositories.contains(repository.id) { await Task.yield() }
        try await model.unregister(repository)
        await refresh.value
        #expect(model.loadingRepositories.isEmpty)
        #expect(model.worktrees.isEmpty && model.settings.worktreeIdentities.isEmpty)
    }

    @Test func relativeWorktreeDestinationIsRejected() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let repository = try #require(model.settings.repositories.first)
        await #expect(throws: (any Error).self) {
            try await model.createWorktree(repository: repository, branch: "relative", startPoint: "refs/heads/main", path: "relative", existing: false)
        }
        #expect(try await fixture.service.worktrees(repository, executable: fixture.executable).count == 1)
    }

    @Test(arguments: [false, true]) func commandFailureCleansUpItsChild(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-command-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let task = Task {
            try await CommandRunner().run(ProcessRequest(executable: "/bin/sh", arguments: [
                "-c", "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "probe", pidFile.path,
            ], timeout: .seconds(2)))
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let identity = try #require(ProcessSnapshot.read(pid)?.identity)
        defer {
            if ProcessSnapshot.read(pid)?.identity == identity { _ = Darwin.kill(pid, SIGKILL) }
        }
        if cancel {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: CommandFailure.timeout) { try await task.value }
        }
        let remaining = ProcessSnapshot.read(pid)
        #expect(remaining == nil || remaining?.identity != identity || remaining?.isZombie == true)
    }

    @Test func commandTimeoutCleansUpAnOrphanThatIgnoresTerminate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-orphan-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        await #expect(throws: CommandFailure.timeout) {
            try await CommandRunner().run(ProcessRequest(executable: "/bin/sh", arguments: [
                "-c", "(trap '' TERM; exec /bin/sleep 30) & printf '%s' \"$!\" > \"$1\"; exit 0", "probe", pidFile.path,
            ], timeout: .milliseconds(300)))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let remaining = ProcessSnapshot.read(pid)
        defer {
            if let remaining, ProcessSnapshot.read(pid)?.identity == remaining.identity { _ = Darwin.kill(pid, SIGKILL) }
        }
        #expect(remaining == nil || remaining?.isZombie == true)
    }

    @Test func cancellingAQueuedCommandDoesNotWaitForTheRunningCommand() async throws {
        actor Started {
            var value = false
            func mark() { value = true }
        }
        let gate = AsyncGate(limit: 1), started = Started()
        let holder = Task {
            try await gate.withPermit {
                await started.mark()
                try await Task.sleep(for: .seconds(1))
            }
        }
        while await !started.value { await Task.yield() }
        let waiter = Task { try await gate.withPermit { true } }
        try await Task.sleep(for: .milliseconds(20))
        let begin = ContinuousClock.now
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(ContinuousClock.now - begin < .milliseconds(500))
        try await holder.value
        #expect(try await gate.withPermit { true })
    }

    @Test(arguments: [false, true]) func restartCannotLaunchAfterStopOrClose(close: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let execution = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "ZDOTDIR": fixture.root.path])
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service, execution: execution)
        await model.load()
        try await model.register(fixture.path)
        let tree = try #require(model.worktrees.first)
        let definition = TaskDefinition(name: "restart", command: .shell("trap '' INT; printf READY; /bin/sleep 30"))
        let entry = try await execution.run(definition, worktree: tree, shell: "/bin/zsh")
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while !String(decoding: entry.session.output.data, as: UTF8.self).contains("READY"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let restarting = Task { try await model.runTask(definition, worktreeID: tree.id, restarting: entry) }
            while entry.session.phase != .stopping, ContinuousClock.now < deadline { await Task.yield() }
            #expect(entry.session.phase == .stopping)
            if close { try await execution.close(entry) }
            else { try await execution.stopEverything() }
            await #expect(throws: CancellationError.self) { try await restarting.value }
            #expect(!execution.hasActiveSession)
            #expect(execution.entries.count == (close ? 0 : 1))
        } catch { _ = await execution.prepareToQuit(); throw error }
    }

    @Test func oversizedSettingsReadPreservesOriginalAndBlocksSaves() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let url = fixture.root.appendingPathComponent("oversized.json")
        let oversized = Data(repeating: 32, count: 8 * 1024 * 1024 + 1)
        try oversized.write(to: url)
        let store = SettingsStore(url: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save(AppSettings(), revision: 1) }
        #expect(try Data(contentsOf: url) == oversized)
    }

    @Test func globalLogEvictionNotifiesTheAlreadyFinishedRun() {
        let logs = TaskLogStore(perRunLimit: 10, totalLimit: 15)
        let finished = UUID(), running = UUID()
        var notifications: [UUID] = []
        logs.onTruncation = { notifications.append($0) }
        logs.append(Array("1234567890".utf8)[...], to: finished)
        logs.append(Array("abcdefghij".utf8)[...], to: running)
        #expect(notifications == [finished])
        #expect(logs.isTruncated(finished) && logs.data(for: finished).isEmpty)
    }

    @Test func terminationWaitsForRegistrationAndCanResumeAfterCancellation() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let url = fixture.root.appendingPathComponent("settings.json")
        let model = DashboardModel(store: SettingsStore(url: url), git: fixture.service)
        await model.load()
        let wrapper = fixture.root.appendingPathComponent("slow-git")
        try Data("#!/bin/sh\n/bin/sleep .1\nexec /usr/bin/git \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        model.settings.gitPath = wrapper.path
        let registration = Task { try await model.register(fixture.path) }
        while !model.isRegistering { await Task.yield() }
        await model.prepareForTermination()
        try await registration.value
        await model.save()
        #expect(model.isTerminating && !model.isRegistering)
        #expect(try await SettingsStore(url: url).load().repositories.count == 1)
        await #expect(throws: CancellationError.self) {
            try await fixture.service.identify(fixture.path, executable: fixture.executable)
        }
        await model.cancelTermination()
        await model.refreshAll()
        #expect(!model.isTerminating && model.worktrees.count == 1)
    }
}
