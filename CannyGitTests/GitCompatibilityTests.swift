import Foundation
import Testing

struct CommandResult: Sendable {
    let status: Int32
    let output: Data
}

// Test fixtures run on a background executor and use files rather than pipes,
// so even a failing command cannot deadlock on a full stdout/stderr pipe.
func runFixtureCommand(_ executable: String, _ arguments: [String], directory: URL) async throws -> CommandResult {
    try await Task.detached {
        let outputURL = directory.appendingPathComponent("command-\(UUID()).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": directory.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "CannyGit Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "CannyGit Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: try Data(contentsOf: outputURL))
    }.value
}

struct GitCompatibilityTests {
    @Test func actualWorktreeLifecycleWithUnusualPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-git-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("원본 저장소")
        let worktree = root.appendingPathComponent("워크 트리\n한글")

        func git(_ arguments: [String], status: Int32 = 0) async throws -> Data {
            let result = try await runFixtureCommand("/usr/bin/git", arguments, directory: root)
            #expect(result.status == status, "\(String(decoding: result.output, as: UTF8.self))")
            return result.output
        }
        _ = try await git(["init", "--template=", "-b", "main", repository.path])
        _ = try await git(["-C", repository.path, "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Fixture"])
        _ = try await git(["-C", repository.path, "worktree", "add", "-b", "feature/probe", "--", worktree.path, "main"])
        let list = try await git(["-C", repository.path, "worktree", "list", "--porcelain", "-z"])
        #expect(list.contains(0))
        let paths = list.split(separator: 0)
            .filter { $0.starts(with: "worktree ".utf8) }
            .compactMap { String(bytes: $0.dropFirst(9), encoding: .utf8) }
        #expect(paths.count == 2)
        #expect(paths.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                == worktree.resolvingSymlinksInPath().path
        })

        let mainCommon = try await git(["-C", repository.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let linkedCommon = try await git(["-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        #expect(mainCommon == linkedCommon)
        let file = worktree.appendingPathComponent("변경 파일\n이름.txt")
        try Data("fixture".utf8).write(to: file)
        let status = try await git(["--no-optional-locks", "-C", worktree.path, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"])
        #expect(status.range(of: Data("? 변경 파일\n이름.txt\0".utf8)) != nil)
        let refused = try await runFixtureCommand("/usr/bin/git", ["-C", repository.path, "worktree", "remove", "--", worktree.path], directory: root)
        #expect(refused.status != 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        _ = try await git(["-C", repository.path, "worktree", "remove", "--", worktree.path])
        #expect(!FileManager.default.fileExists(atPath: worktree.path))

        // Existing local branch names must remain attached, not detached refs.
        _ = try await git(["-C", repository.path, "worktree", "add", "--", worktree.path, "feature/probe"])
        let branch = try await git(["-C", worktree.path, "symbolic-ref", "HEAD"])
        #expect(String(decoding: branch, as: UTF8.self) == "refs/heads/feature/probe\n")
        _ = try await git(["-C", repository.path, "worktree", "remove", "--", worktree.path])
    }
}
