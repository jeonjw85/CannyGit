import Foundation
import Testing
@testable import CannyGit

struct RepositoryFixture: Sendable {
    let root: URL
    let path: URL
    let service: GitService
    var executable: String { "/usr/bin/git" }

    static func create(commit: Bool = true) async throws -> RepositoryFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-product-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("원본 repository")
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_DIR": "/not/the/selected/repository"]
        let fixture = RepositoryFixture(root: root, path: path, service: GitService(environment: env))
        _ = try await fixture.git(["init", "--template=", "-b", "main", path.path])
        if commit {
            _ = try await fixture.git(["-C", path.path, "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Fixture"])
        }
        return fixture
    }

    func git(_ args: [String]) async throws -> Data {
        let result = try await runFixtureCommand(executable, args, directory: root)
        guard result.status == 0 else { throw ExecutionError(message: "Fixture Git 실패: \(String(decoding: result.output, as: UTF8.self))") }
        return result.output
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

struct GitParserTests {
    private let headers = "# branch.oid abcdef\0# branch.head main\0"

    @Test func nulPathsRenameConflictAndCounts() throws {
        let source = headers + "# branch.upstream origin/main\0# branch.ab +3 -2\0"
            + "1 MM N... 100644 100644 100644 abc def 한글 파일\n이름\0"
            + "2 R. N... 100644 100644 100644 abc def R100 새 이름\0이전\n이름\0"
            + "u UU N... 100644 100644 100644 100644 abc def ghi conflict\0"
            + "? untracked dir/\0! ignored/\0"
        let result = try GitParser.status(Data(source.utf8))
        #expect(result.files.count == 4)
        #expect(result.staged == 2)
        #expect(result.unstaged == 1)
        #expect(result.conflicts == 1)
        #expect(result.untracked == 1)
        #expect(result.files[1].originalPath == "이전\n이름")
        #expect(result.files[0].path == "한글 파일\n이름")
        #expect(result.ahead == 3 && result.behind == 2)
        #expect(result.ignored == ["ignored/"])
    }

    @Test func detachedUnbornAndLockedWithoutReason() throws {
        let data = Data("worktree /tmp/bare\0bare\0\0worktree /tmp/한글\n경로\0HEAD abc\0detached\0locked\0prunable missing path\0\0".utf8)
        let trees = try GitParser.worktrees(data, repositoryID: UUID())
        #expect(trees[0].isMain && trees[0].isBare)
        #expect(trees[1].branchRef == nil && trees[1].locked == "")
        #expect(trees[1].prunable == "missing path")
        let unborn = try GitParser.status(Data("# branch.oid (initial)\0# branch.head main\0# future.key ignored\0".utf8))
        #expect(unborn.isUnborn && unborn.head == nil && unborn.upstream == nil)
        let detached = try GitParser.status(Data("# branch.oid abc\0# branch.head (detached)\0".utf8))
        #expect(detached.branch == nil)
    }

    @Test func malformedOutputNeverBecomesClean() throws {
        #expect(throws: (any Error).self) { try GitParser.status(Data()) }
        #expect(throws: (any Error).self) { try GitParser.status(Data((headers + "future dirty\0").utf8)) }
        #expect(throws: (any Error).self) { try GitParser.status(Data((headers + "2 R. broken\0").utf8)) }
        #expect(throws: (any Error).self) { try GitParser.worktrees(Data("worktree /tmp\0\0".utf8), repositoryID: UUID()) }
        #expect(throws: (any Error).self) { try GitParser.text([UInt8(255)]) }
    }
}

struct GitServiceTests {
    @Test func registerCreateDirtyRefusalLockedIgnoredAndDelete() async throws {
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
        let destination = fixture.root.appendingPathComponent("한글 linked\n경로")
        try await fixture.service.create(repository: repository, branch: "feature/ui", startPoint: "refs/heads/main",
            destination: destination, existing: false, executable: fixture.executable)
        let nested = destination.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let same = try await fixture.service.identify(nested, executable: fixture.executable)
        #expect(same.commonDirectory == repository.commonDirectory)
        let trees = try await fixture.service.worktrees(repository, executable: fixture.executable)
        let linked = try #require(trees.first { !$0.isMain })
        #expect(linked.branchRef == "refs/heads/feature/ui")
        #expect(linked.gitDirectory != repository.commonDirectory)
        try Data("dirty".utf8).write(to: destination.appendingPathComponent("untracked"))
        await #expect(throws: (any Error).self) {
            try await fixture.service.remove(repository: repository, worktree: linked, executable: fixture.executable)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("untracked"))
        _ = try await fixture.git(["-C", fixture.path.path, "worktree", "lock", destination.path])
        await #expect(throws: (any Error).self) {
            try await fixture.service.removalPreview(repository: repository, worktree: linked, executable: fixture.executable)
        }
        _ = try await fixture.git(["-C", fixture.path.path, "worktree", "unlock", destination.path])
        try FileManager.default.createDirectory(at: fixture.path.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        try Data(".cache-test\n".utf8).write(to: fixture.path.appendingPathComponent(".git/info/exclude"))
        try Data("ignored".utf8).write(to: destination.appendingPathComponent(".cache-test"))
        let preview = try await fixture.service.removalPreview(repository: repository, worktree: linked, executable: fixture.executable)
        #expect(preview.ignoredPaths == [".cache-test"])
        try await fixture.service.remove(repository: repository, worktree: linked, executable: fixture.executable)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let branch = try await fixture.service.branches(repository, executable: fixture.executable)
        #expect(branch.contains { $0.ref == "refs/heads/feature/ui" })
        try await fixture.service.create(repository: repository, branch: "feature/ui", startPoint: "",
            destination: destination, existing: true, executable: fixture.executable)
        let attached = try await fixture.service.worktrees(repository, executable: fixture.executable)
        #expect(attached.contains { $0.branchRef == "refs/heads/feature/ui" })
    }

    @Test func unbornBareAndOccupiedBranches() async throws {
        let fixture = try await RepositoryFixture.create(commit: false)
        defer { fixture.cleanUp() }
        let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
        let status = try await fixture.service.status(path: fixture.path.path, executable: fixture.executable)
        #expect(status.isUnborn)
        await #expect(throws: (any Error).self) {
            try await fixture.service.create(repository: repository, branch: "new", startPoint: "refs/heads/main",
                destination: fixture.root.appendingPathComponent("linked"), existing: false, executable: fixture.executable)
        }
        let bare = fixture.root.appendingPathComponent("bare.git")
        _ = try await fixture.git(["init", "--bare", "--template=", bare.path])
        let bareRepository = try await fixture.service.identify(bare, executable: fixture.executable)
        let trees = try await fixture.service.worktrees(bareRepository, executable: fixture.executable)
        #expect(trees.count == 1 && trees[0].isBare && !trees[0].canExecute)
    }

    @Test func commandLimitsTimeoutAndCancellation() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(ProcessRequest(executable: "/usr/bin/python3", arguments: ["-c",
            "import os; os.write(1,b'a'*200000); os.write(2,b'b'*200000)"]))
        #expect(result.stdout.count == 200_000 && result.stderr.count == 200_000)
        await #expect(throws: CommandFailure.outputLimit) {
            try await runner.run(ProcessRequest(executable: "/usr/bin/python3", arguments: ["-c", "print('x'*100000)"], outputLimit: 1000))
        }
        await #expect(throws: CommandFailure.timeout) {
            try await runner.run(ProcessRequest(executable: "/bin/sleep", arguments: ["5"], timeout: .milliseconds(50)))
        }
        let task = Task { try await runner.run(ProcessRequest(executable: "/bin/sleep", arguments: ["5"])) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func gateSerializesAcrossSuspensionPoints() async throws {
        actor Counter {
            var current = 0
            var maximum = 0
            func operation() async throws {
                current += 1; maximum = max(maximum, current)
                try await Task.sleep(for: .milliseconds(30))
                current -= 1
            }
        }
        let gate = AsyncGate(limit: 1), counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { try await gate.withPermit { try await counter.operation() } } }
            try await group.waitForAll()
        }
        #expect(await counter.maximum == 1)
    }
}
