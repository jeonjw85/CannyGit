import SwiftUI

struct CannyGitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: DashboardModel = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CANNYGIT_TEST_SETTINGS"] {
            return DashboardModel(store: SettingsStore(url: URL(fileURLWithPath: path)))
        }
        if environment["CANNYGIT_TEST_HOST"] == "1" || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return DashboardModel(store: SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("CannyGit-test-host-\(UUID())/settings.json")))
        }
        return DashboardModel()
    }()

    var body: some Scene {
        Window("CannyGit", id: "main") {
            DashboardView(model: model)
                .onAppear { delegate.coordinator = model.execution; delegate.model = model }
        }
        .defaultSize(width: 1320, height: 900)
        .commands { WindowCommands(model: model) }
        Settings { SettingsView(model: model) }
        Window("명령 팔레트", id: "command-palette") { CommandPalette(model: model) }
            .windowResizability(.contentSize).defaultPosition(.center)
        #if DEBUG
        Window("터미널 기술 검증", id: "probe") { TerminalProbeView(coordinator: model.execution) }
        #endif
    }
}

private struct WindowCommands: Commands {
    let model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("CannyGit 열기") { openWindow(id: "main") }
            Button("저장소 등록") { model.chooseRepository() }.keyboardShortcut("o").disabled(!model.isLoaded)
            Button("새로고침") { Task { await model.refreshAll() } }.keyboardShortcut("r").disabled(!model.isLoaded)
            Button("명령 팔레트") {
                guard NSApp.modalWindow == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return }
                openWindow(id: "command-palette")
            }.keyboardShortcut("k").disabled(!model.isLoaded)
            #if DEBUG
            Button("터미널 기술 검증") { openWindow(id: "probe") }
            #endif
        }
    }
}
