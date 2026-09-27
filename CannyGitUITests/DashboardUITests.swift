import AppKit
import Carbon
import XCTest

@MainActor
final class DashboardUITests: XCTestCase {
    @MainActor private final class ClipboardState {
        var original: [[String: Data]]?
        var change: Int?
    }
    private let clipboard = ClipboardState()

    @MainActor private final class InputSourceRestore {
        let original: TISInputSource
        init(_ original: TISInputSource) { self.original = original }
        func restore() { TISSelectInputSource(original) }
    }

    func testPaletteDiffGroupsAndTerminalLayout() throws {
        continueAfterFailure = false
        useASCIIInputSource()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CannyGit-V2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("V2 Repo")
        try git(["init", "--template=", "-b", "main", repository.path], root: root)
        let file = repository.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: file)
        try git(["-C", repository.path, "add", "file.txt"], root: root)
        try git(["-C", repository.path, "-c", "commit.gpgSign=false", "commit", "-m", "Fixture"], root: root)
        try Data("working\n".utf8).write(to: file)
        let app = XCUIApplication()
        app.launchEnvironment["CANNYGIT_TEST_SETTINGS"] = root.appendingPathComponent("settings.json").path
        app.launchEnvironment["HOME"] = root.path
        app.launchEnvironment["ZDOTDIR"] = root.path
        app.launchArguments = ["-AppleLanguages", "(ko)", "-optionAsMetaKey", "NO"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["registerRepository"].waitForExistence(timeout: 10))
        app.buttons["registerRepository"].click()
        XCTAssertTrue(app.dialogs["open-panel"].waitForExistence(timeout: 5))
        enterFolderPath(repository, in: app)
        let choose = app.dialogs["open-panel"].buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        waitUntilReady(choose)
        choose.click()
        XCTAssertTrue(app.dialogs["open-panel"].waitForNonExistence(timeout: 10), app.dialogs["open-panel"].debugDescription)
        XCTAssertTrue(app.staticTexts["V2 Repo"].firstMatch.waitForExistence(timeout: 15), app.dialogs["open-panel"].debugDescription)
        app.buttons["toggleTerminalPanel"].click()
        app.descendants(matching: .tab)["변경"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["file.txt"].firstMatch.waitForExistence(timeout: 10), app.windows["main"].debugDescription)
        app.staticTexts["file.txt"].firstMatch.click()
        let diff = app.textViews["diffContent"]
        XCTAssertTrue(diff.waitForExistence(timeout: 10))
        XCTAssertTrue((diff.value as? String)?.contains("+working") == true)

        palette(app, query: "terminal V2")
        XCTAssertTrue(app.buttons["shell 1"].firstMatch.waitForExistence(timeout: 10))
        let pid = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'PID '")).firstMatch
        let original = try XCTUnwrap(pid.value as? String)
        app.buttons["maximizeTerminal"].click()
        app.buttons["maximizeTerminal"].click()
        app.buttons["hideTerminal"].click()
        XCTAssertTrue(app.buttons["shell 1"].firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["toggleTerminalPanel"].click()
        XCTAssertTrue(app.buttons["shell 1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(pid.value as? String, original)
        palette(app, query: "activity")
        XCTAssertTrue(app.staticTexts["전체 실행 현황"].waitForExistence(timeout: 5))
        palette(app, query: "worktree V2 main")
        app.descendants(matching: .tab)["작업"].firstMatch.click()
        addTask(app, name: "Setup", command: "printf ready > setup-done")
        addTask(app, name: "Finish", command: "test -f setup-done && printf GROUP_OK > group-done")
        app.descendants(matching: .tab)["그룹"].firstMatch.click()
        app.buttons["addTaskGroup"].click()
        let name = app.textFields["groupName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Dev Stack")
        app.checkBoxes.matching(identifier: "Setup").element(boundBy: 0).click()
        app.buttons["다음 단계 추가"].click()
        app.checkBoxes.matching(identifier: "Finish").element(boundBy: 1).click()
        app.buttons["saveTaskGroup"].click()
        let run = app.buttons["runGroup-Dev Stack"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.click()
        waitForFile(repository.appendingPathComponent("group-done")) { $0 == "GROUP_OK" }
        XCTAssertTrue(app.buttons["shell 1"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        shot.name = "CannyGit-0.2-groups"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.dialogs.buttons["중지하고 종료"].firstMatch.waitForExistence(timeout: 5))
        app.dialogs.buttons["중지하고 종료"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch()
        XCTAssertTrue(app.staticTexts["V2 Repo"].firstMatch.waitForExistence(timeout: 15))
        app.descendants(matching: .tab)["그룹"].firstMatch.click()
        XCTAssertTrue(app.buttons["runGroup-Dev Stack"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    func testRegisterCreateTaskDeleteRestoreAndQuit() throws {
        continueAfterFailure = false
        useASCIIInputSource()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CannyGit-UI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("UI Test Repo")
        try git(["init", "--template=", "-b", "main", repository.path], root: root)
        try git(["-C", repository.path, "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Fixture"], root: root)
        let app = XCUIApplication()
        app.launchEnvironment["CANNYGIT_TEST_SETTINGS"] = root.appendingPathComponent("settings.json").path
        app.launchEnvironment["HOME"] = root.path
        app.launchEnvironment["ZDOTDIR"] = root.path
        app.launchArguments = ["-AppleLanguages", "(ko)", "-optionAsMetaKey", "NO"]
        app.launch()
        defer { app.terminate() }

        let register = app.buttons["registerRepository"]
        XCTAssertTrue(register.waitForExistence(timeout: 10))
        register.click()
        XCTAssertTrue(app.dialogs["open-panel"].waitForExistence(timeout: 5))
        enterFolderPath(repository, in: app)
        let choose = app.dialogs["open-panel"].buttons["OKButton"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        waitUntilReady(choose)
        choose.click()
        XCTAssertTrue(app.dialogs["open-panel"].waitForNonExistence(timeout: 10), app.dialogs["open-panel"].debugDescription)
        XCTAssertTrue(app.staticTexts["UI Test Repo"].firstMatch.waitForExistence(timeout: 15), app.dialogs.debugDescription)

        app.buttons["createWorktree"].click()
        let branch = app.textFields["newBranchName"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        branch.click()
        branch.typeText("feature/ui-test")
        app.buttons["confirmCreateWorktree"].click()
        XCTAssertTrue(app.staticTexts["feature/ui-test"].firstMatch.waitForExistence(timeout: 15))

        let tasksTab = app.descendants(matching: .tab)["작업"].firstMatch
        XCTAssertTrue(tasksTab.waitForExistence(timeout: 5))
        tasksTab.click()
        app.buttons["addTask"].click()
        let name = app.textFields["taskName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("UI Check")
        let command = app.descendants(matching: .any)["taskCommand"].firstMatch
        command.click()
        command.typeText("printf UI_DONE")
        app.buttons["saveTask"].click()
        let run = app.buttons["runTask-UI Check"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.click()
        let completed = app.staticTexts["완료 · 종료 0"].firstMatch.waitForExistence(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = "CannyGit-product-dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(completed, app.windows["main"].debugDescription)

        let linked = root.appendingPathComponent("UI Test Repo-worktrees/feature-ui-test")
        let dirty = linked.appendingPathComponent("untracked.txt")
        try Data("fixture".utf8).write(to: dirty)
        app.buttons["removeWorktree"].click()
        XCTAssertTrue(app.staticTexts["변경 또는 미추적 항목이 있는 워크트리는 삭제할 수 없습니다."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirmRemoveWorktree"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        try FileManager.default.removeItem(at: dirty)
        app.buttons["removeWorktree"].click()
        let remove = app.buttons["confirmRemoveWorktree"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertTrue(remove.isEnabled)
        remove.click()
        XCTAssertTrue(app.staticTexts["feature/ui-test"].firstMatch.waitForNonExistence(timeout: 15))

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.staticTexts["UI Test Repo"].firstMatch.waitForExistence(timeout: 15))
        let terminal = app.buttons["openTerminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.click()
        XCTAssertTrue(app.buttons["shell 1"].firstMatch.waitForExistence(timeout: 10), app.windows["main"].debugDescription)
        app.windows["main"].coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.82)).click()
        app.typeText("printf '한글' > terminal-check.txt\n")
        let output = repository.appendingPathComponent("terminal-check.txt")
        let inputDelivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: output, encoding: .utf8)) == "한글"
        }, object: nil)
        let delivery = XCTWaiter.wait(for: [inputDelivered], timeout: 10)
        if delivery != .completed {
            let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
            screenshot.name = "terminal-input"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(delivery, .completed, "\((try? String(contentsOf: output, encoding: .utf8)) ?? "file missing")")
        // XCTest's Unicode-Hex key synthesis commits UTF-16 surrogate halves
        // separately. Paste verifies an actual, complete emoji input string.
        app.typeText("printf '%s' '")
        paste("한글🙂", into: app)
        app.typeText("' > paste-check.txt\n")
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: repository.appendingPathComponent("paste-check.txt"), encoding: .utf8)) == "한글🙂"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 10), .completed)
        app.typeText("/usr/bin/vim -Nu NONE -i NONE -n -c 'call writefile([\"ready\"], \"vim-ready\")' vim-check.txt\n")
        waitForFile(repository.appendingPathComponent("vim-ready")) { $0.contains("ready") }
        app.typeText("iTUI_OK")
        app.typeKey(.escape, modifierFlags: [])
        app.typeText(":wq\n")
        waitForFile(repository.appendingPathComponent("vim-check.txt")) { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "TUI_OK" }
        app.typeText("/bin/sleep 30 & echo $! > job.pid; fg\n")
        waitForFile(repository.appendingPathComponent("job.pid")) { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
        app.typeKey("z", modifierFlags: .control)
        app.typeText("jobs -l > suspended-job.txt\n")
        waitForFile(repository.appendingPathComponent("suspended-job.txt")) { $0.contains("suspended") || $0.contains("stopped") }
        app.typeText("fg\n")
        app.typeKey("c", modifierFlags: .control)
        app.typeText("printf done > interrupt-check.txt\n")
        waitForFile(repository.appendingPathComponent("interrupt-check.txt")) { $0 == "done" }
        app.typeKey("d", modifierFlags: .control)
        XCTAssertTrue(app.staticTexts["완료 · 종료 0"].firstMatch.waitForExistence(timeout: 10))
        terminal.click()
        XCTAssertTrue(app.buttons["shell 2"].firstMatch.waitForExistence(timeout: 10))
        let pidLabel = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'PID '")).firstMatch
        let originalPID = try XCTUnwrap(pidLabel.value as? String)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows["main"].waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(app.state, .notRunning)
        app.menuBars.menuBarItems["파일"].click()
        app.menuItems["CannyGit 열기"].click()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shell 2"].firstMatch.exists)
        XCTAssertEqual(pidLabel.value as? String, originalPID)
        app.typeKey("q", modifierFlags: .command)
        let cancel = app.dialogs.buttons["취소"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertEqual(app.state, .runningForeground)
        app.typeKey("q", modifierFlags: .command)
        app.dialogs.buttons["중지하고 종료"].firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    private func waitForFile(_ url: URL, matches: @escaping (String) -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return matches(value)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, url.lastPathComponent)
    }

    private func waitUntilReady(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isEnabled && element.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func useASCIIInputSource() {
        let original = InputSourceRestore(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(ascii), noErr)
        addTeardownBlock { await original.restore() }
    }

    private func enterFolderPath(_ url: URL, in app: XCUIApplication) {
        let choose = app.dialogs["open-panel"].buttons["OKButton"]
        waitUntilReady(choose)
        app.typeText("/")
        // The system Go to Folder overlay is not exposed as an app text field.
        // Its modal state is observable; paste avoids losing characters to its
        // presentation animation or the current input method.
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !choose.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 5), .completed)
        app.typeKey("a", modifierFlags: .command)
        paste(url.path, into: app)
        app.typeKey(.return, modifierFlags: [])
        let navigated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (app.dialogs["open-panel"].popUpButtons["where popup"].value as? String) == url.lastPathComponent
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [navigated], timeout: 10), .completed)
    }

    private func palette(_ app: XCUIApplication, query: String) {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["paletteSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(query)
        search.typeKey(.return, modifierFlags: [])
    }

    private func addTask(_ app: XCUIApplication, name: String, command: String) {
        app.buttons["addTask"].click()
        let field = app.textFields["taskName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(name)
        let input = app.descendants(matching: .any)["taskCommand"].firstMatch
        input.click(); input.typeText(command)
        app.buttons["saveTask"].click()
        XCTAssertTrue(app.buttons["runTask-\(name)"].waitForExistence(timeout: 10))
    }

    private func paste(_ text: String, into app: XCUIApplication) {
        let board = NSPasteboard.general
        if clipboard.original == nil {
            let previous = (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type.rawValue, $0) }
                })
            }
            clipboard.original = previous
            addTeardownBlock { [clipboard] in
                await MainActor.run {
                    let board = NSPasteboard.general
                    guard board.changeCount == clipboard.change else { return }
                    board.clearContents()
                    board.writeObjects(previous.map { values in
                        let item = NSPasteboardItem()
                        for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                        return item
                    })
                }
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        clipboard.change = board.changeCount
        app.typeKey("v", modifierFlags: .command)
    }

    private func git(_ arguments: [String], root: URL) throws {
        let process = Process()
        // Apple's /usr/bin/git shim invokes xcrun, which is unavailable inside
        // the UI test runner's sandbox. Use the selected Xcode's actual Git.
        let developer = try XCTUnwrap(ProcessInfo.processInfo.environment["CANNYGIT_DEVELOPER_DIR"])
        process.executableURL = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "CannyGit UI Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "CannyGit UI Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
}
