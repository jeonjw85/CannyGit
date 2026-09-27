import AppKit
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct PerformanceTests {
    @Test(.timeLimit(.minutes(35)))
    func boundedOutputSoak() async throws {
        _ = NSApplication.shared
        let seconds = max(5, Int(ProcessInfo.processInfo.environment["CANNYGIT_SOAK_SECONDS"] ?? "10") ?? 10)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-soak-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
            import os, time, tty, select, sys
            tty.setraw(0)
            deadline = time.monotonic() + \(seconds + 10)
            while time.monotonic() < deadline:
                sys.stdout.buffer.write(b'cannygit bounded terminal output 0123456789\\r\\n' * 200)
                sys.stdout.buffer.flush()
                if select.select([0], [], [], 0)[0]:
                    if b'PING' in os.read(0, 4096): os.write(1, b'PONG\\r\\n')
                time.sleep(0.01)
            """
        let session = TerminalSession(configuration: TerminalLaunch(executable: "/usr/bin/python3", arguments: ["-c", script], directory: root))
        let logs = TaskLogStore()
        session.onOutput = { logs.append($0, to: session.id) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "CannyGit 출력 검증"
        window.contentView = session.terminalView
        window.orderFront(nil)
        defer { window.orderOut(nil); session.onOutput = nil }
        await session.start()
        let started = ContinuousClock.now
        var samples: [(Int, UInt64)] = []
        do {
            while ContinuousClock.now - started < .seconds(seconds) {
                try await Task.sleep(for: .seconds(1))
                var info = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.stride)
                guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else {
                    throw ExecutionError(message: "메모리 계측 실패")
                }
                samples.append((samples.count + 1, info.pti_resident_size))
                #expect(session.isActive)
                #expect(session.output.count <= 64 * 1024)
                #expect(logs.totalBytes <= 50 * 1024 * 1024)
                session.send(Data("PING".utf8))
                session.resize(columns: samples.count.isMultiple(of: 2) ? 80 : 90, rows: 24)
            }
            try await session.stop(timing: StopTiming(interrupt: .milliseconds(50), terminate: .milliseconds(50)))
            let retained = logs.data(for: session.id)
            #expect(retained.count <= 5 * 1024 * 1024)
            #expect(String(decoding: retained, as: UTF8.self).contains("PONG"))
            let steady = samples.suffix(max(1, samples.count / 2)).map(\.1)
            let growth = (steady.max() ?? 0) - (steady.min() ?? 0)
            if seconds >= 60 { #expect(growth < 128 * 1024 * 1024) }
            let milestones = samples.filter { $0.0.isMultiple(of: 60) || $0.0 == samples.count }
            print("CANNYGIT_SOAK seconds=\(seconds) outputBytes=\(session.output.totalBytes) retained=\(retained.count) steadyRSSGrowth=\(growth) minuteSamples=\(milestones)")
        } catch {
            try? await session.stop(timing: StopTiming(interrupt: .zero, terminate: .zero))
            throw error
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func tenRepositoriesFiftyWorktreesAndTenTerminals() async throws {
        _ = NSApplication.shared
        var fixtures: [RepositoryFixture] = []
        defer { fixtures.forEach { $0.cleanUp() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-scale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path])
        let service = GitService(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        let model = DashboardModel(store: SettingsStore(url: root.appendingPathComponent("settings.json")), git: service, execution: coordinator)
        await model.load()
        for index in 0..<10 {
            let fixture = try await RepositoryFixture.create()
            fixtures.append(fixture)
            let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
            for branch in 0..<4 {
                try await fixture.service.create(repository: repository, branch: "scale-\(index)-\(branch)", startPoint: "refs/heads/main",
                    destination: fixture.root.appendingPathComponent("tree-\(branch)"), existing: false, executable: fixture.executable)
            }
            try await model.register(fixture.path)
        }
        model.selectRepository(nil)
        #expect(model.settings.repositories.count == 10 && model.worktrees.count == 50)
        var worst: Duration = .zero
        for tree in model.worktrees {
            let start = ContinuousClock.now
            model.selectedWorktreeID = tree.id
            _ = model.visibleWorktrees
            _ = model.selectedWorktree
            worst = max(worst, ContinuousClock.now - start)
        }
        #expect(worst < .milliseconds(100))
        let command = TaskDefinition(name: "scale", command: .executable("/bin/sleep", ["30"]))
        let script = try #require(Bundle.module.url(forResource: "http_server", withExtension: "py", subdirectory: "Fixtures"))
        let server = TaskDefinition(name: "HTTP", command: .executable("/usr/bin/python3", [script.path]), kind: .server)
        do {
            for (index, tree) in model.worktrees.prefix(10).enumerated() {
                try await coordinator.run(index < 3 ? server : command, worktree: tree, shell: "/bin/zsh")
            }
            #expect(coordinator.entries.filter { $0.session.isActive }.count == 10)
            let deadline = ContinuousClock.now + .seconds(10)
            while coordinator.entries.filter({ !$0.ports.isEmpty }).count < 3 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(coordinator.entries.filter { !$0.ports.isEmpty }.count == 3)
            #expect(await coordinator.prepareToQuit())
            print("CANNYGIT_SCALE repositories=10 worktrees=50 PTYs=10 servers=3 worstCachedSelection=\(worst)")
        } catch { _ = await coordinator.prepareToQuit(); throw error }
    }
}
