import Darwin
import Foundation
#if SWIFT_PACKAGE
import CannyPTY
#endif

struct TerminalLaunch: Sendable {
    var executable: String
    var arguments: [String]
    var directory: URL
    var environment: [String: String] = ProcessInfo.processInfo.environment

    static var accountShell: String {
        guard let shell = getpwuid(getuid())?.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }
}

enum ProcessExit: Equatable, Sendable {
    case code(Int32)
    case signal(Int32)
    case unavailable

    init(waitStatus: Int32) {
        if cg_wait_exited(waitStatus) != 0 {
            self = .code(cg_wait_exit_code(waitStatus))
        } else if cg_wait_signaled(waitStatus) != 0 {
            self = .signal(cg_wait_signal(waitStatus))
        } else {
            self = .unavailable
        }
    }
}

struct ExecutionError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(message: String.LocalizationValue) {
        self.message = String(localized: message)
    }

    static func system(_ operation: String.LocalizationValue, code: Int32 = errno) -> Self {
        Self(message: "\(String(localized: operation)): \(String(cString: strerror(code))) (\(code))")
    }
}

struct PTYLaunchResult: Sendable {
    let pid: Int32
    let descriptor: Int32
    let identity: ProcessIdentity
}

enum PTYLauncher {
    private static let queue = DispatchQueue(label: "CannyGit.PTYLaunch", qos: .userInitiated)

    static func launch(_ configuration: TerminalLaunch) async throws -> PTYLaunchResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try performLaunch(configuration) })
            }
        }
    }

    // A dedicated serial queue keeps blocking exec handshakes off both the UI
    // and cooperative executor, and prevents descriptors racing another fork.
    private static func performLaunch(_ configuration: TerminalLaunch) throws -> PTYLaunchResult {
        var environment = configuration.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
            environment.removeValue(forKey: key)
        }
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "CannyGit"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let arguments = [configuration.executable] + configuration.arguments
        let variables = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let strings = arguments + variables + [configuration.directory.path]
        guard configuration.directory.isFileURL,
            configuration.executable.hasPrefix("/"),
            !strings.contains(where: { $0.utf8.contains(0) })
        else {
            throw ExecutionError(message: "실행 경로와 작업 디렉터리를 확인하세요.")
        }

        return try withCStringArray(arguments) { argv in
            try withCStringArray(variables) { envp in
                var result = CGPTYLaunch()
                let code = cg_pty_spawn(
                    configuration.executable, argv, envp, configuration.directory.path,
                    80, 24, &result
                )
                guard code == 0 else {
                    let operation: String.LocalizationValue = switch result.error_stage {
                    case 2: "작업 디렉터리 열기 실패"
                    case 3: "실행 파일 시작 실패"
                    default: "PTY 시작 실패"
                    }
                    throw ExecutionError.system(operation, code: code)
                }
                return PTYLaunchResult(pid: result.pid, descriptor: result.master_fd,
                    identity: ProcessIdentity(pid: result.pid, seconds: result.start_seconds,
                                              microseconds: result.start_microseconds))
            }
        }
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else {
                throw ExecutionError.system("실행 인자 할당 실패", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}
