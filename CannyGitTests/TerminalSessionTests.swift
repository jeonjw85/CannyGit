import AppKit
import Testing
@testable import CannyGit

#if !SWIFT_PACKAGE
private final class FixtureBundleToken: NSObject {}
extension Bundle {
    static var module: Bundle { Bundle(for: FixtureBundleToken.self) }
}
#endif

@Suite(.serialized)
@MainActor
struct TerminalSessionTests {
    @Test func launchFailuresAreNotExit127() async throws {
        let missing = makeSession(executable: "/no/such/canny-executable")
        await missing.start()
        #expect(missing.phase == .failed)
        #expect(missing.exit == nil)
        #expect(!missing.isActive)

        let wrongDirectory = makeSession(directory: URL(fileURLWithPath: "/no/such/canny-directory"))
        await wrongDirectory.start()
        #expect(wrongDirectory.phase == .failed)
        #expect(wrongDirectory.errorMessage?.contains(String(localized: "작업 디렉터리 열기 실패")) == true)

        let genuine = makeSession(arguments: ["-fc", "exit 127"])
        await genuine.start()
        try await finished(genuine)
        #expect(genuine.exit == .code(127))
    }

    @Test func fastExitPreservesStatusAndFinalOutput() async throws {
        for code in [0, 1, 42, 255, 0, 42, 0, 42] {
            let session = makeSession(arguments: ["-fc", "printf '마지막 출력'; exit \(code)"])
            await session.start()
            try await finished(session)
            #expect(session.exit == .code(Int32(code)))
            #expect(text(session).contains("마지막 출력"))
            #expect(session.errorMessage == nil)
        }
    }

    @Test func fastExitSurvivesDelayedUIDeliveryAndConcurrentLaunches() async throws {
        let sessions = (0..<10).map { _ in makeSession(arguments: ["-fc", "printf ready; exit 0"]) }
        let tasks = sessions.map { session in Task { await session.start() } }
        try await Task.sleep(for: .milliseconds(5))
        // Intentionally simulate a busy UI thread after fork/exec has completed.
        usleep(300_000)
        for task in tasks { await task.value }
        for session in sessions {
            try await finished(session)
            #expect(session.exit == .code(0))
            #expect(text(session).contains("ready"))
            #expect(session.errorMessage == nil)
        }
    }

    @Test func signalsAndEOFAreIndependent() async throws {
        let signaled = makeSession(arguments: ["-fc", "kill -TERM $$"])
        await signaled.start()
        try await finished(signaled)
        #expect(signaled.exit == .signal(SIGTERM))

        let earlyEOF = makeSession(arguments: ["-fc", "exec </dev/null >/dev/null 2>&1; sleep 0.2; exit 9"])
        await earlyEOF.start()
        try await finished(earlyEOF)
        #expect(earlyEOF.exit == .code(9))
    }

    @Test func directoryAndResizeReachTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canny-\(UUID()) 공백 한글\n경로")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession(arguments: ["-fc", "read ignored; pwd; stty size"], directory: directory)
        await session.start()
        session.resize(columns: 93, rows: 31)
        session.send(Data("\n".utf8))
        try await finished(session)
        #expect(text(session).contains(directory.resolvingSymlinksInPath().path.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(text(session).contains("31 93"))
    }

    @Test func outputFloodRemainsBounded() async throws {
        let session = makeSession(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os; os.write(1, b'x' * 2_000_000); os.write(1, '끝🙂'.encode())"]
        )
        await session.start()
        try await finished(session, seconds: 15)
        #expect(session.exit == .code(0))
        #expect(session.output.totalBytes >= 2_000_000)
        #expect(session.output.count == 64 * 1024)
        #expect(text(session).hasSuffix("끝🙂"))
    }

    @Test func stopRemovesMultipleJobGroupsAndListeners() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
        let session = makeSession(arguments: [
            "-fm", "-c", "\"$1\" \"$2\" & \"$1\" \"$2\" & wait",
            "canny-fixture", "/usr/bin/python3", fixture.path,
        ])
        await session.start()
        do {
            try await until { text(session).components(separatedBy: "SERVER ").count >= 3 }
            try await until { session.ownedPIDs.count >= 3 }
            let pids = session.ownedPIDs
            let identities = pids.compactMap(ProcessSnapshot.read).map(\.identity)
            let groups = Set(pids.compactMap(ProcessSnapshot.read).map(\.groupID))
            #expect(groups.count >= 2)
            let listening = try await runFixtureCommand(
                "/usr/sbin/lsof", ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                directory: FileManager.default.temporaryDirectory
            )
            #expect(listening.status == 0)
            #expect(String(decoding: listening.output, as: UTF8.self).contains("n127.0.0.1:"))
            try await session.stop(timing: StopTiming(interrupt: .milliseconds(50), terminate: .milliseconds(100)))
            #expect(!session.isActive)
            for identity in identities {
                let current = ProcessSnapshot.read(identity.pid)
                #expect(current == nil || current?.identity != identity || current?.isZombie == true)
            }
            let stopped = try await runFixtureCommand(
                "/usr/sbin/lsof", ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                directory: FileManager.default.temporaryDirectory
            )
            #expect(stopped.status == 1)
            #expect(stopped.output.isEmpty)
        } catch {
            try? await session.stop(timing: StopTiming(interrupt: .zero, terminate: .zero))
            throw error
        }
    }

    @Test func orphanedJobRemainsOwnedAfterShellExit() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
        let session = makeSession(arguments: [
            "-fc", "\"$1\" \"$2\" & sleep 0.3; exit 7",
            "canny-fixture", "/usr/bin/python3", fixture.path,
        ])
        await session.start()
        do {
            try await until { session.exit == .code(7) && text(session).contains("SERVER ") }
            #expect(session.isActive)
            try await session.stop(timing: StopTiming(interrupt: .zero, terminate: .milliseconds(50)))
            #expect(!session.isActive)
            #expect(session.exit == .code(7))
        } catch {
            try? await session.stop(timing: StopTiming(interrupt: .zero, terminate: .zero))
            throw error
        }
    }

    @Test func cancelDuringLaunch() async throws {
        let session = makeSession(arguments: ["-fc", "sleep 30"])
        let start = Task { await session.start() }
        try await session.stop()
        await start.value
        try await finished(session)
        #expect(session.wasStopped)
    }

    @Test func pidReuseDoesNotAuthorizeSignals() async throws {
        let current = try #require(ProcessSnapshot.read(getpid()))
        let reused = ProcessIdentity(
            pid: current.identity.pid, seconds: current.identity.seconds + 1,
            microseconds: current.identity.microseconds
        )
        let supervisor = ProcessSupervisor(root: reused)
        #expect(try await supervisor.members().isEmpty)
        try await supervisor.stop(foregroundGroup: current.groupID, timing: StopTiming(interrupt: .zero))
        #expect(ProcessSnapshot.read(getpid())?.identity == current.identity)
    }

    @Test func quitCoordinatorWaitsForCleanup() async throws {
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("canny-home-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = ExecutionCoordinator(environment: [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "ZDOTDIR": home.path,
        ])
        coordinator.shell = "/bin/zsh"
        coordinator.command = "exec /bin/sleep 30"
        await coordinator.start()
        let session = try #require(coordinator.session)
        #expect(session.isActive)
        #expect(await coordinator.prepareToQuit())
        #expect(!session.isActive)
        #expect(session.wasStopped)
    }

    @Test func splitUTF8AndLargeInputArePreserved() async throws {
        let program = """
            import os, tty
            tty.setraw(0)
            for byte in '준비🙂'.encode():
                os.write(1, bytes([byte]))
            received = 0
            while received < 300000:
                received += len(os.read(0, min(4096, 300000 - received)))
            os.write(1, ('DONE ' + str(received)).encode())
            """
        let session = makeSession(executable: "/usr/bin/python3", arguments: ["-c", program])
        await session.start()
        do {
            try await until { text(session).contains("준비🙂") }
            session.send(Data(repeating: 97, count: 300_000))
            try await finished(session)
            #expect(text(session).hasSuffix("DONE 300000"))
            #expect(session.exit == .code(0))
            #expect(session.errorMessage == nil)
        } catch {
            try? await session.stop(timing: StopTiming(interrupt: .zero, terminate: .zero))
            throw error
        }
    }

    private func makeSession(
        executable: String = "/bin/zsh", arguments: [String] = ["-fc", "exit 0"],
        directory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalSession {
        _ = NSApplication.shared
        return TerminalSession(configuration: TerminalLaunch(
            executable: executable, arguments: arguments, directory: directory
        ))
    }

    private func text(_ session: TerminalSession) -> String {
        String(decoding: session.output.data, as: UTF8.self)
    }

    private func finished(_ session: TerminalSession, seconds: Int = 8) async throws {
        do { try await until(seconds: seconds) { !session.isActive } }
        catch {
            try? await session.stop(timing: StopTiming(interrupt: .zero, terminate: .zero))
            throw error
        }
    }

    private func until(seconds: Int = 8, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now >= deadline {
                throw ExecutionError(message: "테스트 대기 시간 초과")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
