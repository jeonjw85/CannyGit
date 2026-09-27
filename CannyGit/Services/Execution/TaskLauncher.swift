import Foundation

protocol TaskLaunchPreparing: Sendable {
    func configuration(task: TaskDefinition, root: URL, shell: String, environment: [String: String]) async throws -> TerminalLaunch
}

actor TaskLauncher: TaskLaunchPreparing {
    func configuration(task: TaskDefinition, root: URL, shell: String, environment: [String: String]) throws -> TerminalLaunch {
        guard !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            task.expectedPorts.allSatisfy({ (1...65535).contains($0) })
        else { throw ExecutionError(message: "작업 이름과 예상 포트(1~65535)를 확인하세요.") }
        if !task.serverURL.isEmpty {
            guard let url = URL(string: task.serverURL), ["http", "https"].contains(url.scheme), url.host != nil else {
                throw ExecutionError(message: "서버 URL은 http 또는 https 주소여야 합니다.")
            }
        }
        let directory = try TaskDetector.directory(root: root, relative: task.directory)
        var env = environment
        for (key, reference) in task.environmentReferences {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                let value = environment[reference]
            else { throw ExecutionError(message: "환경 변수 참조를 찾을 수 없습니다: \(key) ← \(reference)") }
            env[key] = value
        }
        let arguments: [String]
        switch task.command {
        case .shell(let command):
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExecutionError(message: "실행할 명령을 입력하세요.")
            }
            arguments = ["-lc", command]
        case .executable(let executable, let args):
            guard !executable.isEmpty else { throw ExecutionError(message: "실행 파일을 지정하세요.") }
            let name = URL(fileURLWithPath: shell).lastPathComponent
            if name == "fish" { arguments = ["-lc", "exec $argv", executable] + args }
            else if ["zsh", "bash", "sh", "ksh"].contains(name) {
                // Only this constant program is shell syntax; all detected values are argv.
                arguments = ["-lc", "exec \"$@\"", "cannygit-task", executable] + args
            } else {
                throw ExecutionError(message: "이 셸의 인자 실행 방식은 지원하지 않습니다. zsh/bash/fish를 선택하거나 셸 명령으로 등록하세요.")
            }
        }
        return TerminalLaunch(executable: shell, arguments: arguments, directory: directory, environment: env)
    }
}
