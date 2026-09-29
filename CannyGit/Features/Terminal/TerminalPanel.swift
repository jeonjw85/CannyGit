import SwiftUI

struct TerminalPanel: View {
    @Bindable var model: DashboardModel
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("optionAsMetaKey") private var optionAsMetaKey = false
    @State private var closing: SessionEntry?

    private var entries: [SessionEntry] { model.selectedWorktree.map { model.execution.entries(for: $0.id) } ?? [] }
    private var selected: SessionEntry? {
        guard let tree = model.selectedWorktree else { return nil }
        return entries.first { $0.id == model.execution.selectedSessions[tree.id] } ?? entries.last
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("터미널", systemImage: "terminal").font(.caption.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(entries) { entry in
                            HStack(spacing: 5) {
                                Button {
                                    model.execution.selectedSessions[entry.worktreeID] = entry.id
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: entry.status.symbol).foregroundStyle(entry.status.color)
                                        Text(entry.title).lineLimit(1)
                                    }
                                }.buttonStyle(.plain).accessibilityLabel(entry.title).accessibilityValue(entry.status.title)
                                Button {
                                    if entry.session.isActive { closing = entry }
                                    else { Task { try? await model.execution.close(entry) } }
                                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).accessibilityLabel("\(entry.title) 탭 닫기")
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(selected?.id == entry.id ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .help("시작: \(entry.startedAt.formatted())\n셸: \(entry.session.configuration.executable)\n디렉터리: \(entry.session.configuration.directory.path)")
                        }
                    }
                }
                Menu {
                    ForEach(entries) { entry in
                        Button("\(entry.title) · \(entry.status.title)") { model.execution.selectedSessions[entry.worktreeID] = entry.id }
                    }
                } label: { Image(systemName: "list.bullet") }
                .help("터미널 탭 목록").disabled(entries.isEmpty)
                Button {
                    guard let tree = model.selectedWorktree else { return }
                    Task { do { try await model.openTerminal(tree.id) }
                        catch is CancellationError {}
                        catch { model.errorMessage = error.localizedDescription } }
                } label: { Image(systemName: "plus") }
                .disabled(model.selectedWorktree?.canExecute != true).help("새 터미널")
                if let selected {
                    Button { Task { do { try await selected.session.stop() } catch { model.errorMessage = error.localizedDescription } } }
                        label: { Image(systemName: "stop.fill") }.disabled(!selected.session.isActive).help("세션 중지")
                    Button { Task { await model.execution.exportLog(selected) } }
                        label: { Image(systemName: "square.and.arrow.up") }.help("출력 로그 내보내기")
                }
                Button {
                    model.terminalPresentation = model.terminalPresentation == .maximized ? .normal : .maximized
                } label: { Image(systemName: model.terminalPresentation == .maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .help("터미널 최대화 / 복원").accessibilityIdentifier("maximizeTerminal")
                Button { model.terminalPresentation = .hidden } label: { Image(systemName: "chevron.down") }
                    .help("터미널 숨기기").accessibilityIdentifier("hideTerminal")
            }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            if let selected {
                TerminalHost(session: selected.session, fontSize: fontSize, optionAsMetaKey: optionAsMetaKey).id(selected.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        StatusBadge(status: selected.status)
                        if selected.groupRunID != nil { Label("그룹 작업", systemImage: "square.stack.3d.up").foregroundStyle(.secondary) }
                        Text(selected.resultDescription)
                        if let pid = selected.session.pid { Text("PID \(pid)").foregroundStyle(.secondary) }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(RunDuration.format((selected.endedAt ?? context.date).timeIntervalSince(selected.startedAt)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let address = selected.task?.serverURL, let url = URL(string: address), !address.isEmpty {
                            Button("설정 URL 열기") { model.openURL(url) }.buttonStyle(.link)
                        }
                        ForEach(selected.ports.prefix(6)) { port in
                            Menu(":\(port.port)") {
                                Text("\(port.host):\(port.port) · PID \(port.pid)")
                                Button("HTTP로 열기") { if let url = port.browserURL(scheme: "http") { model.openURL(url) } }
                                Button("HTTPS로 열기") { if let url = port.browserURL(scheme: "https") { model.openURL(url) } }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }
                        if !selected.urlCandidates.isEmpty {
                            Menu("출력 URL") { ForEach(selected.urlCandidates, id: \.self) { url in Button(url.absoluteString) { model.openURL(url) } } }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    if let error = selected.session.errorMessage ?? selected.portError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if let error = selected.conflictError { Text("예상 포트 조회 실패: \(error)").foregroundStyle(.orange) }
                    if !selected.conflicts.isEmpty {
                        Text("예상 포트 점유: \(selected.conflicts.map { "\($0.port) · \($0.processName) PID \($0.pid)" }.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                        if let date = selected.conflictsCheckedAt {
                            Text("확인 시각: \(date.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                        }
                    }
                    if let task = selected.task, !task.expectedPorts.isEmpty {
                        Text("예상: \(task.expectedPorts.map(String.init).joined(separator: ", ")) · LISTEN은 HTTP 정상 응답을 보장하지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                    if selected.logTruncated { Text("로그 상한을 넘어 오래된 출력이 잘렸습니다.").foregroundStyle(.secondary) }
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 5)
            } else {
                ContentUnavailableView("열린 터미널 없음", systemImage: "terminal",
                    description: Text("워크트리 선택 후 + 또는 작업 실행"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("세션을 중지하고 탭을 닫을까요?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("중지하고 닫기", role: .destructive) {
                guard let entry = closing else { return }
                Task { do { try await model.execution.close(entry) } catch { model.errorMessage = error.localizedDescription } }
            }
            Button("취소", role: .cancel) {}
        } message: { Text("이 세션의 셸과 자식 작업을 함께 중지합니다.") }
    }
}
