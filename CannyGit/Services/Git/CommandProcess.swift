import Darwin
import Foundation

enum CommandProcess {
    // Suspend before exec can finish so even a fast parent cannot disappear before
    // its birth identity and private process group have been recorded.
    static func spawn(_ request: ProcessRequest, stdout: Int32, stderr: Int32) throws -> ProcessIdentity {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask)
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
        if let directory = request.directory {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        let environment = request.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        try withStrings([request.executable] + request.arguments) { argv in
            try withStrings(environment) { envp in
                try check(posix_spawn(&pid, request.executable, &actions, &attributes, argv, envp))
            }
        }
        do {
            guard let process = ProcessSnapshot.read(pid), process.groupID == pid else {
                throw ExecutionError(message: "시작한 프로세스의 소유 정보를 확인할 수 없습니다.")
            }
            guard kill(pid, SIGCONT) == 0 else { throw ExecutionError.system("명령 시작 실패") }
            return process.identity
        } catch {
            // This is still our unreaped child, so its PID cannot have been reused.
            _ = kill(pid, SIGKILL)
            while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
            throw error
        }
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw ExecutionError.system("명령 시작 실패", code: code) }
    }

    private static func withStrings<T>(_ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw ExecutionError.system("실행 인자 할당 실패", code: ENOMEM) }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}
