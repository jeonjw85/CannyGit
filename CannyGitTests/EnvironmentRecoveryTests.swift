import AppKit
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct EnvironmentRecoveryTests {
    @Test func detachedVolumeIsMarkedStaleAndReattachesWithItsSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-volume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("fixture.dmg"), mount = root.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await tool("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "HFS+", "-volname", "CannyGitFixture", image.path], root: root)
        var mounted = false
        do {
            try await tool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mount.path, image.path], root: root)
            mounted = true
            let repositoryURL = mount.appendingPathComponent("repository")
            try await tool("/usr/bin/git", ["init", "--template=", "-b", "main", repositoryURL.path], root: root)
            try await tool("/usr/bin/git", ["-C", repositoryURL.path, "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Fixture"], root: root)
            let service = GitService(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
            let model = DashboardModel(store: SettingsStore(url: root.appendingPathComponent("settings.json")), git: service)
            await model.load()
            try await model.register(repositoryURL)
            await model.refreshAll()
            let repository = try #require(model.settings.repositories.first)
            let original = try #require(model.worktrees.first)
            let task = TaskDefinition(name: "kept", command: .shell("exit 0"))
            await model.saveTask(task, tree: original, shared: false)
            await service.suspend()
            try await tool("/usr/bin/hdiutil", ["detach", mount.path], root: root)
            mounted = false
            await service.resume()
            await model.refreshAll()
            #expect(model.repositoryErrors[repository.id] != nil)
            #expect(model.worktrees.first?.id == original.id)
            #expect(model.worktrees.first?.error != nil)
            #expect(model.worktrees.first?.status?.collectedAt == original.status?.collectedAt)
            try await tool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mount.path, image.path], root: root)
            mounted = true
            try Data("changed".utf8).write(to: repositoryURL.appendingPathComponent("after-remount.txt"))
            await model.refreshAll()
            let recovered = try #require(model.worktrees.first)
            #expect(recovered.id == original.id && recovered.error == nil)
            #expect(model.repositoryErrors[repository.id] == nil)
            #expect(recovered.status?.untracked == 1)
            #expect(model.candidates(for: recovered).contains { $0.id == task.id })
            await service.suspend()
            try await tool("/usr/bin/hdiutil", ["detach", mount.path], root: root)
            mounted = false
        } catch {
            if mounted { _ = try? await runFixtureCommand("/usr/bin/hdiutil", ["detach", "-force", mount.path], directory: root) }
            throw error
        }
    }

    @Test func loginProfileProvidesToolsMissingFromFinderLikePATH() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let bin = fixture.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("fixture-tool")
        try Data("#!/bin/sh\nprintf 'PROFILE_TOOL_OK:%s:%s:%s\\n' \"$PWD\" \"$1\" \"$LOCAL_SETTING\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("export PATH=\"$HOME/bin:/usr/bin:/bin\"\n".utf8).write(to: fixture.root.appendingPathComponent(".zprofile"))
        let literal = "한글 ; $(exit 99)"
        let definition = TaskDefinition(name: "profile", command: .executable("fixture-tool", [literal]), environmentReferences: ["LOCAL_SETTING": "SOURCE_SETTING"])
        let launch = try await TaskLauncher().configuration(task: definition, root: fixture.path, shell: "/bin/zsh", environment: [
            "PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "ZDOTDIR": fixture.root.path, "SOURCE_SETTING": "fixture-value",
        ])
        let session = TerminalSession(configuration: launch)
        await session.start()
        do {
            try await until { !session.isActive }
            #expect(session.exit == .code(0))
            let output = String(decoding: session.output.data, as: UTF8.self)
            #expect(output.contains("PROFILE_TOOL_OK:"))
            #expect(output.contains(fixture.path.resolvingSymlinksInPath().path))
            #expect(output.contains(literal + ":fixture-value"))
        } catch { try? await session.stop(); throw error }
    }

    @Test func nonExecutableGitRetainsDataAsStaleAndRecovers() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let model = DashboardModel(store: SettingsStore(url: fixture.root.appendingPathComponent("settings.json")), git: fixture.service)
        await model.load()
        try await model.register(fixture.path)
        let original = try #require(model.worktrees.first)
        let blocked = fixture.root.appendingPathComponent("blocked-git")
        try Data("fixture".utf8).write(to: blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path)
        model.settings.gitPath = blocked.path
        await model.refreshAll()
        #expect(model.worktrees.first?.id == original.id)
        #expect(model.worktrees.first?.status != nil)
        #expect(model.worktrees.first?.error != nil)
        #expect(await ToolInspector().inspect(kind: .git, path: blocked.path, execute: true).valid == false)
        model.settings.gitPath = fixture.executable
        await model.refreshAll()
        #expect(model.worktrees.first?.error == nil && model.repositoryErrors.isEmpty)
    }

    private func tool(_ executable: String, _ arguments: [String], root: URL) async throws {
        let result = try await runFixtureCommand(executable, arguments, directory: root)
        guard result.status == 0 else { throw ExecutionError(message: "Fixture command failed: \(String(decoding: result.output, as: UTF8.self))") }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExecutionError(message: "Environment verification timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
