import Foundation

enum ToolKind: String, CaseIterable, Identifiable, Sendable {
    case git, shell, editor
    var id: Self { self }
    var title: String {
        switch self {
        case .git: "Git"
        case .shell: String(localized: "셸")
        case .editor: String(localized: "에디터 앱")
        }
    }
}

struct ToolCheck: Sendable {
    let valid: Bool
    let detail: String
}

actor ToolInspector {
    private let runner = CommandRunner()

    func candidates() -> [ToolKind: [String]] {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let git = directories.map { $0 + "/git" }
        let shells = [TerminalLaunch.accountShell] + directories.flatMap { path in ["zsh", "bash", "fish"].map { path + "/" + $0 } }
        return [.git: existing(git), .shell: existing(shells)]
    }

    func inspect(kind: ToolKind, path: String, execute: Bool) async -> ToolCheck {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            return ToolCheck(valid: false, detail: String(localized: "절대 경로 선택"))
        }
        if kind == .editor {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "app", let executable = Bundle(url: url)?.executableURL,
                FileManager.default.isExecutableFile(atPath: executable.path) else {
                return ToolCheck(valid: false, detail: String(localized: "실행 가능한 앱 번들을 찾지 못했습니다."))
            }
            return ToolCheck(valid: true, detail: String(localized: "앱 번들과 실행 파일 확인"))
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return ToolCheck(valid: false, detail: String(localized: "파일이 없거나 실행 권한이 없습니다."))
        }
        guard execute else { return ToolCheck(valid: true, detail: String(localized: "실행 파일 확인")) }
        do {
            let arguments = kind == .git ? ["--version"] : ["-lc", "printf CANNYGIT_SHELL_READY"]
            let result = try await runner.run(ProcessRequest(executable: path, arguments: arguments,
                directory: FileManager.default.homeDirectoryForCurrentUser, timeout: .seconds(8), outputLimit: 64 * 1024))
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = result.status == 0 && (kind == .git ? output.hasPrefix("git version ") : output.contains("CANNYGIT_SHELL_READY"))
            let message = valid ? (kind == .git ? output : String(localized: "로그인 셸 명령 모드 실행 확인"))
                : String(localized: "실행 실패 (\(result.status)): \(String(decoding: result.stderr, as: UTF8.self))")
            return ToolCheck(valid: valid, detail: String(message.prefix(1000)))
        } catch { return ToolCheck(valid: false, detail: error.localizedDescription) }
    }

    private func existing(_ paths: [String]) -> [String] {
        Array(Set(paths.filter { FileManager.default.isExecutableFile(atPath: $0) })).sorted()
    }
}
