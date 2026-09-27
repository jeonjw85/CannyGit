import SwiftUI
import UniformTypeIdentifiers

struct ToolSettingsView: View {
    @Bindable var model: DashboardModel
    @State private var paths: [ToolKind: String] = [:]
    @State private var candidates: [ToolKind: [String]] = [:]
    @State private var checks: [ToolKind: ToolCheck] = [:]
    @State private var busy = false
    @State private var saved = false
    private let inspector = ToolInspector()

    var body: some View {
        Section("도구") {
            ForEach(ToolKind.allCases) { kind in
                HStack {
                    TextField(kind.title, text: Binding(get: { paths[kind] ?? "" }, set: {
                        paths[kind] = $0; checks.removeValue(forKey: kind); saved = false
                    }))
                    Button("찾아보기…") { browse(kind) }
                    if let options = candidates[kind], !options.isEmpty {
                        Menu("발견한 경로") {
                            ForEach(options, id: \.self) { path in
                                Button(path) { paths[kind] = path; checks.removeValue(forKey: kind); saved = false }
                            }
                        }
                    }
                }
                if let result = checks[kind] {
                    Label(result.detail, systemImage: result.valid ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(result.valid ? .green : .orange).textSelection(.enabled)
                }
            }
            HStack {
                Button("설치 경로 찾기") { discover() }
                Button("버전·실행 진단") { checkAndSave(save: false) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("도구 설정 저장") { checkAndSave(save: true) }.disabled(!model.isLoaded)
            }
            .disabled(busy)
            Text("진단은 Git 버전과 셸의 -lc 명령 모드를 실행합니다. 셸 초기화 파일에 따라 Finder 실행 환경의 PATH가 달라질 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if saved { Label("저장했습니다", systemImage: "checkmark.circle").foregroundStyle(.green) }
            if let error = model.saveError { Text(error).foregroundStyle(.red) }
        }
        .onAppear(perform: loadPaths)
        .onChange(of: model.isLoaded) { _, loaded in if loaded { loadPaths() } }
    }

    private func loadPaths() {
        paths = [.git: model.settings.gitPath, .shell: model.settings.shellPath, .editor: model.settings.editorPath]
    }

    private func browse(_ kind: ToolKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if kind == .editor { panel.allowedContentTypes = [.application] }
        if panel.runModal() == .OK, let url = panel.url {
            paths[kind] = url.path
            checks.removeValue(forKey: kind)
            saved = false
        }
    }

    private func discover() {
        busy = true
        Task {
            candidates = await inspector.candidates()
            candidates[.editor] = ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.sublimetext.4"]
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
            busy = false
        }
    }

    private func checkAndSave(save: Bool) {
        let snapshot = paths
        busy = true
        saved = false
        Task {
            var results: [ToolKind: ToolCheck] = [:]
            for kind in ToolKind.allCases {
                results[kind] = await inspector.inspect(kind: kind, path: snapshot[kind] ?? "", execute: !save)
            }
            guard snapshot == paths else { busy = false; return }
            checks = results
            let valid = results.allSatisfy { kind, result in
                result.valid || (kind == .editor && snapshot[.editor] == model.settings.editorPath)
            }
            if save && valid {
                model.settings.gitPath = snapshot[.git] ?? model.settings.gitPath
                model.settings.shellPath = snapshot[.shell] ?? model.settings.shellPath
                model.settings.editorPath = snapshot[.editor] ?? model.settings.editorPath
                await model.save()
                saved = model.saveError == nil
                await model.refreshAll()
            }
            busy = false
        }
    }
}
