import SwiftUI

struct TaskEditorView: View {
    @Bindable var model: DashboardModel
    let tree: Worktree
    let initial: TaskDefinition
    @Environment(\.dismiss) private var dismiss
    @State private var definition: TaskDefinition
    @State private var shared = true
    @State private var shellMode = true
    @State private var shellCommand = ""
    @State private var executable = ""
    private struct Argument: Identifiable { let id = UUID(); var value: String }
    @State private var arguments: [Argument] = []
    @State private var environment = ""
    @State private var ports = ""
    @State private var error: String?
    @State private var advanced = false
    @State private var saving = false

    init(model: DashboardModel, tree: Worktree, initial: TaskDefinition) {
        self.model = model
        self.tree = tree
        self.initial = initial
        _definition = State(initialValue: initial)
        _shellCommand = State(initialValue: initial.command.display)
        if case .executable(let name, let args) = initial.command {
            _shellMode = State(initialValue: false)
            _executable = State(initialValue: name)
            _arguments = State(initialValue: args.map { Argument(value: $0) })
        }
        _environment = State(initialValue: initial.environmentReferences.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _ports = State(initialValue: initial.expectedPorts.map(String.init).joined(separator: ", "))
        _shared = State(initialValue: !model.settings.taskRules.contains { $0.worktreeID == tree.id && $0.definition.id == initial.id })
        _advanced = State(initialValue: !initial.environmentReferences.isEmpty || !initial.expectedPorts.isEmpty || !initial.serverURL.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("작업 편집").font(.title2.bold())
            Form {
                TextField("이름", text: $definition.name).accessibilityIdentifier("taskName")
                Picker("실행 방식", selection: $shellMode) {
                    Text("셸 명령").tag(true)
                    Text("실행 파일 + 인자").tag(false)
                }.pickerStyle(.segmented)
                if shellMode {
                    TextField("셸 명령", text: $shellCommand, axis: .vertical).lineLimit(3...6)
                        .accessibilityIdentifier("taskCommand")
                } else {
                    TextField("실행 파일", text: $executable)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("인자 · 한 행이 한 인자입니다").font(.caption)
                        ForEach($arguments) { $argument in
                            HStack {
                                TextField("빈 문자열도 인자로 전달됩니다", text: $argument.value, axis: .vertical)
                                    .lineLimit(1...3).font(.system(.body, design: .monospaced))
                                Button { moveArgument(argument.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("인자 위로 이동")
                                Button { moveArgument(argument.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("인자 아래로 이동")
                                Button { arguments.removeAll { $0.id == argument.id } } label: { Image(systemName: "minus.circle") }.help("인자 삭제")
                            }
                        }
                        Button("인자 추가", systemImage: "plus") { arguments.append(Argument(value: "")) }
                    }
                }
                Text("실행 방식을 바꾸면 명령을 직접 확인. 셸 명령은 선택한 셸의 -lc 모드로 실행")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("상대 작업 디렉터리", text: $definition.directory)
                    Button("선택") {
                        Task {
                            do { if let path = try await model.chooseTaskDirectory(tree) { definition.directory = path } }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Picker("종류", selection: $definition.kind) { ForEach(TaskKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                DisclosureGroup("환경 변수·포트·서버 URL", isExpanded: $advanced) {
                TextField("예상 포트 (쉼표 구분)", text: $ports)
                TextField("서버 URL (선택)", text: $definition.serverURL)
                TextField("환경 변수 참조 (KEY=기존_환경변수명)", text: $environment, axis: .vertical).lineLimit(2...5)
                Text("환경 변수 이름만 저장. 비밀 값은 넣지 않음").font(.caption).foregroundStyle(.secondary)
                }
                Picker("저장 범위", selection: $shared) {
                    Text("저장소 공통").tag(true)
                    Text("현재 워크트리").tag(false)
                }.pickerStyle(.segmented)
                Text(shared ? "공통으로 저장하면 현재 워크트리의 같은 작업 재정의를 해제합니다. 다른 워크트리의 재정의는 유지합니다." : "선택한 워크트리의 전체 작업 설정을 재정의합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).autocorrectionDisabled().disabled(saving)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("저장", action: save).keyboardShortcut(.defaultAction).accessibilityIdentifier("saveTask")
                    .disabled(saving)
            }
        }.padding(20).frame(width: 650, height: 680).interactiveDismissDisabled(saving)
    }

    private func save() {
        do {
            guard !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExecutionError(message: "작업 이름 입력") }
            if shellMode {
                guard !shellCommand.isEmpty else { throw ExecutionError(message: "실행할 명령 입력") }
                definition.command = .shell(shellCommand)
            } else {
                guard !executable.isEmpty else { throw ExecutionError(message: "실행 파일 지정") }
                definition.command = .executable(executable, arguments.map(\.value))
            }
            definition.expectedPorts = try ports.split(separator: ",").map {
                guard let port = Int($0.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
                    throw ExecutionError(message: "예상 포트는 1~65535, 쉼표로 구분")
                }
                return port
            }
            var references: [String: String] = [:]
            for line in environment.split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, pair.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }), references[pair[0]] == nil else {
                    throw ExecutionError(message: "환경 변수 참조는 중복 없이 KEY=SOURCE_NAME")
                }
                references[pair[0]] = pair[1]
            }
            definition.environmentReferences = references
            let value = definition, scope = shared
            saving = true
            error = nil
            Task {
                await model.saveTask(value, tree: tree, shared: scope)
                saving = false
                if let error = model.saveError { self.error = error }
                else { dismiss() }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func moveArgument(_ id: UUID, by offset: Int) {
        guard let index = arguments.firstIndex(where: { $0.id == id }), arguments.indices.contains(index + offset) else { return }
        arguments.swapAt(index, index + offset)
    }
}
