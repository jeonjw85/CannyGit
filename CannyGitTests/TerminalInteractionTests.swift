import AppKit
import Testing
@testable import CannyGit

@Suite(.serialized)
@MainActor
struct TerminalInteractionTests {
    @Test func terminalExposesRenderedTextAndSelectionToAccessibility() throws {
        _ = NSApplication.shared
        let session = TerminalSession(configuration: TerminalLaunch(executable: "/bin/zsh", arguments: [], directory: FileManager.default.temporaryDirectory))
        let view = session.terminalView
        view.feed(text: "FIRST 한글🙂\r\nSECOND")
        let output = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(output.isAccessibilityElement())
        #expect(output.accessibilityRole() == .staticText)
        let text = try #require(output.accessibilityValue() as? String)
        #expect(text.contains("FIRST 한글🙂\nSECOND"))
        #expect(!text.contains("\u{0}"))
        let firstLine = output.accessibilityRange(forLine: 0)
        #expect(output.accessibilityString(for: firstLine) == "FIRST 한글🙂")
        #expect(firstLine.length == 10)
        #expect(output.accessibilityLine(for: 11) == 1)
        #expect(output.accessibilityString(for: NSRange(location: Int.max, length: 1)) == nil)
        view.selectAll(nil)
        #expect(output.accessibilitySelectedText()?.contains("FIRST 한글🙂") == true)
    }

    @Test func lessSearchPagingAndQuitReachTheRenderedScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-less-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...160).map { String(format: "ROW_%03d", $0) }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("page.txt"))
        let session = TerminalSession(configuration: TerminalLaunch(executable: "/usr/bin/less", arguments: ["-R", "page.txt"], directory: root,
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "LESSHISTFILE": "-"]))
        await session.start()
        do {
            try await until { screen(session).contains("ROW_001") }
            session.send(Data(" ".utf8))
            try await until { !screen(session).contains("ROW_001") && screen(session).contains("ROW_") }
            session.send(Data("/ROW_150\n".utf8))
            try await until { screen(session).contains("ROW_150") }
            session.resize(columns: 100, rows: 30)
            session.send(Data("q".utf8))
            try await until { !session.isActive }
            #expect(session.exit == .code(0))
        } catch { try? await session.stop(); throw error }
    }

    @Test func topRendersAndAcceptsQuit() async throws {
        let session = TerminalSession(configuration: TerminalLaunch(executable: "/usr/bin/top", arguments: ["-s", "1", "-n", "5"],
            directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]))
        await session.start()
        do {
            try await until { screen(session).contains("Processes:") }
            session.resize(columns: 100, rows: 30)
            session.send(Data("q".utf8))
            try await until { !session.isActive }
            #expect(session.exit == .code(0))
        } catch { try? await session.stop(); throw error }
    }

    private func screen(_ session: TerminalSession) -> String {
        let terminal = session.terminalView.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) }
            .joined(separator: "\n")
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExecutionError(message: "Terminal interaction verification timed out") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
