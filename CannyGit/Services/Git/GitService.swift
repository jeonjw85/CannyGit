import Foundation

actor GitService {
    private let runner: CommandRunner
    private let environment: [String: String]
    private var mutationGates: [UUID: AsyncGate] = [:]
    private var commands: [UUID: Task<ProcessResult, any Error>] = [:]
    private var isSuspended = false

    init(runner: CommandRunner = CommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.environment = environment
    }

    func suspend() async {
        isSuspended = true
        let pending = Array(commands.values)
        pending.forEach { $0.cancel() }
        for command in pending { _ = try? await command.value }
    }

    func resume() { isSuspended = false }

    func identify(_ url: URL, executable: String) async throws -> Repository {
        let path = url.resolvingSymlinksInPath().path
        let common = try GitParser.line(await command(["rev-parse", "--path-format=absolute", "--git-common-dir"], path: path, executable: executable))
        let bare = try GitParser.line(await command(["rev-parse", "--is-bare-repository"], path: path, executable: executable)) == "true"
        let root = bare ? path : try GitParser.line(await command(["rev-parse", "--show-toplevel"], path: path, executable: executable))
        return Repository(name: URL(fileURLWithPath: root).lastPathComponent, path: root,
                          commonDirectory: URL(fileURLWithPath: common).resolvingSymlinksInPath().path)
    }

    func worktrees(_ repository: Repository, executable: String) async throws -> [Worktree] {
        let data = try await command(["worktree", "list", "--porcelain", "-z"], path: repository.commonDirectory, executable: executable)
        var trees = try GitParser.worktrees(data, repositoryID: repository.id)
        for index in trees.indices {
            let path = trees[index].path
            trees[index].isMissing = !FileManager.default.fileExists(atPath: path)
            if !trees[index].isMissing {
                do {
                    let directory = try GitParser.line(await command(["rev-parse", "--absolute-git-dir"], path: path, executable: executable))
                    trees[index].gitDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
                } catch { trees[index].error = error.localizedDescription }
            }
        }
        return trees
    }

    func status(path: String, executable: String, ignored: Bool = false, expandUntracked: Bool = false) async throws -> GitStatusSnapshot {
        var arguments = ["status", "--porcelain=v2", "--branch", "--ahead-behind", "--ignore-submodules=none", "-z",
                         expandUntracked ? "--untracked-files=all" : "--untracked-files=normal"]
        if ignored { arguments.append("--ignored=matching") }
        return try GitParser.status(await command(arguments, path: path, executable: executable))
    }

    func branches(_ repository: Repository, executable: String) async throws -> [GitBranch] {
        try GitParser.branches(await command(
            ["for-each-ref", "--format=%(refname)%00%(objectname)%00", "refs/heads/", "refs/remotes/"],
            path: repository.commonDirectory, executable: executable
        ))
    }

    func diff(worktree: Worktree, file: GitFileChange, scope: DiffScope, executable: String) async throws -> DiffDocument {
        _ = try UntrackedPreview.components(file.path)
        if let original = file.originalPath { _ = try UntrackedPreview.components(original) }
        guard worktree.canExecute else { throw ExecutionError(message: "현재 워크트리에서 diff를 읽을 수 없습니다.") }
        if file.isUntracked {
            if scope == .staged { return DiffDocument(text: "", notice: String(localized: "미추적 파일에는 staged 변경이 없습니다.")) }
            return try UntrackedPreview.read(root: worktree.path, path: file.path)
        }
        var arguments = ["-c", "core.quotePath=false", "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative"]
        if scope == .staged { arguments.append("--cached") }
        arguments += ["--", file.path]
        if let original = file.originalPath { arguments.append(original) }
        let data = try await command(arguments, path: worktree.path, executable: executable, outputLimit: 512 * 1024)
        return DiffDocument(text: try GitParser.text(data), notice: data.isEmpty ? String(localized: "선택한 영역에 변경 내용이 없습니다.") : nil)
    }

    func create(repository: Repository, branch: String, startPoint: String, destination: URL,
                existing: Bool, executable: String) async throws {
        try await gate(repository.id).withPermit {
            try await self.createLocked(repository: repository, branch: branch, startPoint: startPoint,
                                        destination: destination, existing: existing, executable: executable)
        }
    }

    private func createLocked(repository: Repository, branch: String, startPoint: String,
                              destination: URL, existing: Bool, executable: String) async throws {
        let checked = try GitParser.line(await command(["check-ref-format", "--branch", branch], path: repository.commonDirectory, executable: executable))
        guard checked == branch else { throw ExecutionError(message: "브랜치 이름은 직접 입력. 이전 브랜치 표현식은 사용할 수 없습니다.") }
        let trees = try await worktrees(repository, executable: executable)
        guard !trees.contains(where: { $0.branchRef == "refs/heads/\(branch)" }) else {
            throw ExecutionError(message: "다른 워크트리가 이 브랜치를 사용하고 있습니다.")
        }
        let path = destination.resolvingSymlinksInPath().path
        guard destination.isFileURL, path.hasPrefix("/"),
            path != repository.commonDirectory, !path.hasPrefix(repository.commonDirectory + "/"),
            !trees.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path })
        else { throw ExecutionError(message: "워크트리 경로가 기존 경로 또는 Git 메타데이터와 충돌합니다.") }
        if FileManager.default.fileExists(atPath: path) {
            guard try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else {
                throw ExecutionError(message: "대상 폴더가 비어 있지 않습니다.")
            }
        }
        let branches = try await branches(repository, executable: executable)
        if existing {
            guard branches.contains(where: { $0.ref == "refs/heads/\(branch)" }) else {
                throw ExecutionError(message: "선택한 로컬 브랜치가 더 이상 존재하지 않습니다.")
            }
            _ = try await command(["worktree", "add", "--", path, branch], path: repository.commonDirectory, executable: executable)
        } else {
            guard branches.contains(where: { $0.ref == startPoint }) else {
                throw ExecutionError(message: "유효한 기준 브랜치 필요. 첫 커밋 전에는 워크트리를 만들 수 없습니다.")
            }
            let commit = try GitParser.line(await command(["rev-parse", "--verify", "--end-of-options", startPoint + "^{commit}"], path: repository.commonDirectory, executable: executable))
            _ = try await command(["worktree", "add", "-b", branch, "--", path, commit], path: repository.commonDirectory, executable: executable)
        }
        let actual = try GitParser.line(await command(["symbolic-ref", "HEAD"], path: path, executable: executable))
        guard actual == "refs/heads/\(branch)" else {
            throw ExecutionError(message: "워크트리는 만들었지만 브랜치 연결이 예상과 다릅니다. 목록을 다시 확인")
        }
    }

    func removalPreview(repository: Repository, worktree: Worktree, executable: String) async throws -> RemovalPreview {
        let current = try await worktrees(repository, executable: executable)
        guard let tree = current.first(where: { $0.path == worktree.path }),
            !tree.isMain, !tree.isBare, !tree.isMissing, tree.locked == nil
        else { throw ExecutionError(message: "메인·bare·잠김·누락 워크트리는 삭제할 수 없습니다.") }
        guard let directory = worktree.gitDirectory, tree.gitDirectory == directory else {
            throw ExecutionError(message: "워크트리 연결이 바뀌었습니다. 목록 갱신 후 다시 시도")
        }
        let state = try await status(path: tree.path, executable: executable, ignored: true)
        guard state.isClean else { throw ExecutionError(message: "변경 또는 미추적 항목이 있는 워크트리는 삭제할 수 없습니다.") }
        return RemovalPreview(worktree: tree, ignoredPaths: state.ignored)
    }

    func remove(repository: Repository, worktree: Worktree, executable: String) async throws {
        try await gate(repository.id).withPermit {
            _ = try await self.removalPreview(repository: repository, worktree: worktree, executable: executable)
            _ = try await self.command(["worktree", "remove", "--", worktree.path], path: repository.commonDirectory, executable: executable)
        }
    }

    private func gate(_ id: UUID) -> AsyncGate {
        if let gate = mutationGates[id] { return gate }
        let gate = AsyncGate(limit: 1)
        mutationGates[id] = gate
        return gate
    }

    private func command(_ arguments: [String], path: String, executable: String, outputLimit: Int = 8 * 1024 * 1024) async throws -> Data {
        guard !isSuspended else { throw CancellationError() }
        try Task.checkCancellation()
        var env = environment
        for key in env.keys where ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_NAMESPACE", "GIT_SHALLOW_FILE"].contains(key)
            || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") {
            env.removeValue(forKey: key)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        let request = ProcessRequest(
            executable: executable, arguments: ["-C", path, "-c", "color.ui=false"] + arguments, environment: env, outputLimit: outputLimit
        )
        let id = UUID(), runner = self.runner
        let operation = Task { try await runner.run(request) }
        commands[id] = operation
        defer { commands.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
        guard result.status == 0 else {
            let detail = String(decoding: result.stderr, as: UTF8.self)
            throw ExecutionError(message: "Git 오류 (\(result.status)): \(detail)")
        }
        return result.stdout
    }
}
