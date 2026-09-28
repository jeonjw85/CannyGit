import AppKit
import ApplicationServices
import Carbon
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct NativeUIProbe {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2, AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                throw ProbeFailure("Run from an accessibility-authorized terminal: NativeUIProbe <CannyGit.app>")
            }
            try await Probe().run(appURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}

@MainActor
final class Probe {
    private var ownedClipboardChange: Int?

    func run(appURL: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canny-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Native Input Repo")
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path, "ZDOTDIR": root.path,
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                           "GIT_AUTHOR_NAME": "CannyGit Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                           "GIT_COMMITTER_NAME": "CannyGit Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
        try await tool("/usr/bin/git", ["init", "--template=", "-b", "main", repository.path], environment: environment)
        try await tool("/usr/bin/git", ["-C", repository.path, "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Fixture"], environment: environment)
        let settings = root.appendingPathComponent("settings.json"), id = UUID().uuidString
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "repositories": [["id": id, "name": "Native Input Repo", "favorite": false,
                "path": repository.path, "commonDirectory": repository.appendingPathComponent(".git").path]],
            "selectedRepositoryID": id, "shellPath": "/bin/zsh",
        ]).write(to: settings, options: .atomic)
        let board = NSPasteboard.general
        let originalClipboard = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let originalApp = NSWorkspace.shared.frontmostApplication
        defer {
            TISSelectInputSource(originalSource)
            if board.changeCount == ownedClipboardChange {
                board.clearContents()
                board.writeObjects(originalClipboard.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
            originalApp?.activate(options: [])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.environment = environment.merging([
            "CANNYGIT_TEST_SETTINGS": settings.path,
            "CANNYGIT_TEST_INPUT_SOURCE": "com.apple.inputmethod.Korean.2SetKorean",
        ]) { _, value in value }
        configuration.arguments = ["-AppleLanguages", "(ko)", "-optionAsMetaKey", "NO"]
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        let accessibility = AXUIElementCreateApplication(app.processIdentifier)
        do {
            try await wait("test app activation") {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
                app.activate(options: [])
                return false
            }
            try await wait("worktree selection") { self.find(accessibility, "openTerminal") != nil }
            guard let button = find(accessibility, "openTerminal"), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw ProbeFailure("Could not open a terminal using accessibility.")
            }
            try await wait("shell tab") { self.find(accessibility, "shell 1") != nil }
            try await Task.sleep(for: .milliseconds(300))
            try await paste("/usr/bin/python3 -c 'import pathlib,sys; pathlib.Path(\"ime-ready\").write_text(\"ready\"); pathlib.Path(\"ime.txt\").write_text(sys.stdin.readline())'", app: app)
            try await key(36, app: app)
            try await wait("Python reader") { FileManager.default.fileExists(atPath: repository.appendingPathComponent("ime-ready").path) }
            try await Task.sleep(for: .milliseconds(300))
            for code: CGKeyCode in [5, 40, 1, 51, 1, 15, 46, 3, 49, 36] { try await key(code, app: app) }
            let input = repository.appendingPathComponent("ime.txt")
            try await wait("native IME line") { FileManager.default.fileExists(atPath: input.path) }
            let received = try String(contentsOf: input, encoding: .utf8)
            guard received == "한글 \n" else { throw ProbeFailure("Native IME result: \(received.debugDescription)") }
            try await key(0, flags: .maskCommand, app: app)
            try await key(8, flags: .maskCommand, app: app)
            ownedClipboardChange = board.changeCount
            guard board.string(forType: .string)?.contains("한글") == true else { throw ProbeFailure("Terminal selection/copy did not preserve Korean text.") }
            print("PASS native two-set Korean composition, backspace editing, PTY delivery, selection and copy")
            guard let terminal = find(accessibility, "terminalContent"),
                value(terminal, kAXRoleAttribute) as? String == kAXStaticTextRole,
                (value(terminal, kAXValueAttribute) as? String)?.contains("한글") == true,
                (value(terminal, kAXSelectedTextAttribute) as? String)?.contains("한글") == true else {
                throw ProbeFailure("Terminal output or selection is missing from the system accessibility tree.")
            }
            print("PASS system accessibility terminal role, output and selected text")
            try await paste("/usr/bin/python3 -c 'import pathlib,sys; pathlib.Path(\"hanja-ready\").write_text(\"ready\"); pathlib.Path(\"hanja.txt\").write_text(sys.stdin.readline())'", app: app)
            try await key(36, app: app)
            try await wait("Hanja reader") { FileManager.default.fileExists(atPath: repository.appendingPathComponent("hanja-ready").path) }
            try await Task.sleep(for: .milliseconds(300))
            for code: CGKeyCode in [5, 40, 1] { try await key(code, app: app, throughHID: true) }
            try await key(36, flags: .maskAlternate, app: app, throughHID: true)
            try await Task.sleep(for: .milliseconds(500))
            try await key(36, app: app, throughHID: true)
            try await key(49, app: app)
            try await key(36, app: app)
            let hanja = repository.appendingPathComponent("hanja.txt")
            try await wait("Hanja candidate selection") { FileManager.default.fileExists(atPath: hanja.path) }
            let converted = try String(contentsOf: hanja, encoding: .utf8)
            guard converted.range(of: "\\p{Han}", options: .regularExpression) != nil else {
                throw ProbeFailure("Hanja conversion result: \(converted.debugDescription)")
            }
            print("PASS native Hanja candidate selection: \(converted.trimmingCharacters(in: .whitespacesAndNewlines))")
            try await quit(app, accessibility: accessibility)
        } catch {
            try? await quit(app, accessibility: accessibility)
            if !app.isTerminated { app.forceTerminate() }
            throw error
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func find(_ application: AXUIElement, _ identifier: String) -> AXUIElement? {
        var pending = value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var checked = 0
        while let item = pending.popLast(), checked < 2000 {
            checked += 1
            if ["AXIdentifier", kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { value(item, $0) as? String == identifier }) { return item }
            pending += value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return nil
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], app: NSRunningApplication, throughHID: Bool = true) async throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier { app.activate(options: []) }
        try await wait("keyboard focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw ProbeFailure("Could not create key event.") }
            event.flags = flags
            if throughHID { event.post(tap: .cghidEventTap) } else { event.postToPid(app.processIdentifier) }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    private func paste(_ text: String, app: NSRunningApplication) async throws {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        ownedClipboardChange = board.changeCount
        try await key(9, flags: .maskCommand, app: app)
    }

    private func quit(_ app: NSRunningApplication, accessibility: AXUIElement) async throws {
        if app.isTerminated { return }
        app.terminate()
        try await wait("normal app shutdown", seconds: 15) {
            if let confirmation = self.find(accessibility, "중지하고 종료") { AXUIElementPerformAction(confirmation, kAXPressAction as CFString) }
            return app.isTerminated
        }
    }

    private func wait(_ operation: String, seconds: Int = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while !condition() {
            guard Date() < deadline else { throw ProbeFailure("Timed out: \(operation)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func tool(_ executable: String, _ arguments: [String], environment: [String: String]) async throws {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProbeFailure(String(decoding: data, as: UTF8.self)) }
        }.value
    }
}
