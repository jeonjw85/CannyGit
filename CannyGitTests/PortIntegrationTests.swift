import AppKit
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct PortIntegrationTests {
    @Test func twoServersResolveToTheirOwnWorktreesAndStopIndependently() async throws {
        _ = NSApplication.shared
        let fixture = try await RepositoryFixture.create()
        defer { fixture.cleanUp() }
        let repository = try await fixture.service.identify(fixture.path, executable: fixture.executable)
        try await fixture.service.create(repository: repository, branch: "server-two", startPoint: "refs/heads/main",
            destination: fixture.root.appendingPathComponent("server-two"), existing: false, executable: fixture.executable)
        let trees = try await fixture.service.worktrees(repository, executable: fixture.executable)
        let script = try #require(Bundle.module.url(forResource: "http_server", withExtension: "py", subdirectory: "Fixtures"))
        let coordinator = ExecutionCoordinator(environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "ZDOTDIR": fixture.root.path])
        let ports = PortService()
        var definition = TaskDefinition(name: "HTTP", command: .executable("/usr/bin/python3", [script.path]), kind: .server)
        do {
            try await coordinator.run(definition, worktree: trees[0], shell: "/bin/zsh")
            try await until { coordinator.entries[0].ports.count == 1 }
            let first = coordinator.entries[0]
            let firstPort = try #require(first.ports.first)
            definition.expectedPorts = [firstPort.port]
            try await coordinator.run(definition, worktree: trees[1], shell: "/bin/zsh")
            try await until { coordinator.entries[1].ports.count == 1 }
            let second = coordinator.entries[1]
            let secondPort = try #require(second.ports.first)
            #expect(firstPort.port != secondPort.port)
            #expect(second.conflicts.contains { $0.pid == firstPort.pid })
            for (entry, tree) in zip(coordinator.entries, trees) {
                let url = try #require(entry.ports.first?.browserURL(scheme: "http"))
                let (data, response) = try await URLSession.shared.data(from: url)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                let payload = try JSONDecoder().decode([String: String].self, from: data)
                let path = try #require(payload["directory"])
                #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().path)
                #expect(!entry.urlCandidates.isEmpty)
            }
            let owner = try #require(first.session.ownedIdentities.first { $0.pid == firstPort.pid })
            let reused = ProcessIdentity(pid: owner.pid, seconds: owner.seconds + 1, microseconds: owner.microseconds)
            #expect(try await ports.observe([reused]).isEmpty)
            try await coordinator.close(first)
            #expect(second.session.isActive)
            #expect(try await ports.conflicts(ports: [firstPort.port]).isEmpty)
            #expect(try await ports.conflicts(ports: [secondPort.port]).count == 1)
            try await until { second.conflicts.isEmpty }
            #expect(second.conflictError == nil)
            #expect(await coordinator.prepareToQuit())
            #expect(try await ports.conflicts(ports: [secondPort.port]).isEmpty)
        } catch { _ = await coordinator.prepareToQuit(); throw error }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExecutionError(message: "서버 포트 관찰 시간 초과") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
