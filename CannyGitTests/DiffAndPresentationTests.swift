import AppKit
import Testing
@testable import CannyGit

struct DiffServiceTests {
    @Test func stagedAndWorkingDiffAreLiteralAndNeverInvokeExternalConverters() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let name = "tracked [literal].txt"
        let file = fixture.path.appendingPathComponent(name)
        try Data("base\n".utf8).write(to: file)
        _ = try await fixture.git(["-C", fixture.path.path, "--literal-pathspecs", "add", "--", name])
        _ = try await fixture.git(["-C", fixture.path.path, "-c", "commit.gpgSign=false", "commit", "-m", "Fixture file"])
        try Data("staged\n".utf8).write(to: file)
        _ = try await fixture.git(["-C", fixture.path.path, "--literal-pathspecs", "add", "--", name])
        try Data("working\n".utf8).write(to: file)
        let sentinel = fixture.root.appendingPathComponent("external-was-called")
        let script = fixture.root.appendingPathComponent("external.sh")
        try Data("#!/bin/sh\nprintf called > \(TaskCommand.quote(sentinel.path))\n".utf8).write(to: script)
        let external = "/bin/sh " + TaskCommand.quote(script.path)
        _ = try await fixture.git(["-C", fixture.path.path, "config", "diff.external", external])
        _ = try await fixture.git(["-C", fixture.path.path, "config", "diff.fixture.textconv", external])
        try Data("*.txt diff=fixture\n".utf8).write(to: fixture.path.appendingPathComponent(".gitattributes"))
        let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
        let tree = try #require(try await fixture.service.worktrees(repository, executable: fixture.executable).first)
        let status = try await fixture.service.status(path: tree.path, executable: fixture.executable)
        let change = try #require(status.files.first { $0.path == name })
        let staged = try await fixture.service.diff(worktree: tree, file: change, scope: .staged, executable: fixture.executable)
        let working = try await fixture.service.diff(worktree: tree, file: change, scope: .working, executable: fixture.executable)
        #expect(staged.text.contains("+staged") && !staged.text.contains("+working"))
        #expect(working.text.contains("-staged") && working.text.contains("+working"))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func untrackedPreviewsRespectSymlinksBinaryFilesAndSizeLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        #expect(try UntrackedPreview.read(root: root.path, path: "binary").text.isEmpty)
        try Data(repeating: 97, count: 1024).write(to: root.appendingPathComponent("large"))
        #expect(try UntrackedPreview.read(root: root.path, path: "large", limit: 16).notice != nil)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        #expect(try UntrackedPreview.read(root: root.path, path: "link").text == "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc")
        #expect(throws: (any Error).self) { try UntrackedPreview.read(root: root.path, path: "outside/hosts") }
        #expect(throws: (any Error).self) { try UntrackedPreview.read(root: root.path, path: "../hosts") }
    }

    @Test func unbornStagedDiffShowsAddedFile() async throws {
        let fixture = try await RepositoryFixture.create(commit: false)
        defer { fixture.cleanUp() }
        try Data("first\n".utf8).write(to: fixture.path.appendingPathComponent("first.txt"))
        _ = try await fixture.git(["-C", fixture.path.path, "add", "first.txt"])
        let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
        let tree = try #require(try await fixture.service.worktrees(repository, executable: fixture.executable).first)
        let change = try #require(try await fixture.service.status(path: tree.path, executable: fixture.executable).files.first)
        let diff = try await fixture.service.diff(worktree: tree, file: change, scope: .staged, executable: fixture.executable)
        #expect(diff.text.contains("+first"))
    }
}

@Suite(.serialized)
@MainActor
struct PresentationModelTests {
    @Test func failedResultRemainsAfterClosingItsTab() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
        let execution = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path])
        let tree = Worktree(repositoryID: UUID(), path: root.path, gitDirectory: root.path)
        let definition = TaskDefinition(name: "failure", command: .shell("exit 4"))
        try await execution.run(definition, worktree: tree, shell: "/bin/zsh")
        let entry = try #require(execution.entries.last)
        let deadline = ContinuousClock.now + .seconds(5)
        while entry.session.isActive && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if entry.session.isActive { _ = await execution.prepareToQuit() }
        #expect(entry.status == .failed)
        try await execution.close(entry)
        #expect(execution.entries.isEmpty)
        #expect(execution.latestResult(definition.id, worktreeID: tree.id)?.status == .failed)
        #expect(execution.hasFailedTask(worktreeID: tree.id))
        execution.discard(worktreeID: tree.id)
        #expect(execution.latestResult(definition.id, worktreeID: tree.id) == nil)
    }

    @Test func toolDiagnosisReportsMissingFilesAndAnActualGitVersion() async {
        let inspector = ToolInspector()
        let missing = await inspector.inspect(kind: .git, path: "/no/such/git", execute: true)
        #expect(!missing.valid)
        let git = await inspector.inspect(kind: .git, path: "/usr/bin/git", execute: true)
        #expect(git.valid && git.detail.hasPrefix("git version "))
        let editor = await inspector.inspect(kind: .editor, path: "/bin/sh", execute: false)
        #expect(!editor.valid)
    }
}
