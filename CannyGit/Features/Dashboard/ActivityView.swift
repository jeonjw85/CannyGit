import SwiftUI

struct ActivityView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case active, all, failed, changed
        var id: Self { self }
        var title: String {
            switch self {
            case .active: String(localized: "실행 중")
            case .all: String(localized: "전체 기록")
            case .failed: String(localized: "실패")
            case .changed: String(localized: "변경 있는 워크트리")
            }
        }
    }
    @Bindable var model: DashboardModel
    @State private var filter: Filter = .active
    @State private var stopAll = false

    private var displayed: [SessionEntry] {
        model.execution.entries.reversed().filter { entry in
            let tree = model.worktrees.first { $0.id == entry.worktreeID }
            switch filter {
            case .active: if !entry.session.isActive { return false }
            case .failed: if entry.status != .failed { return false }
            case .changed: if tree?.status?.isClean != false { return false }
            case .all: break
            }
            let repository = model.settings.repositories.first { $0.id == entry.repositoryID }
            return model.search.isEmpty || [entry.title, tree?.displayName ?? "", repository?.name ?? "", entry.session.configuration.directory.path]
                .contains { $0.localizedCaseInsensitiveContains(model.search) }
        }
    }

    private var displayedGroups: [TaskGroupRun] {
        model.execution.groups.runs.reversed().filter { run in
            let tree = model.worktrees.first { $0.id == run.worktreeID }
            if filter == .active && !model.execution.groups.canStop(run, execution: model.execution) { return false }
            if filter == .failed && run.status != .failed { return false }
            if filter == .changed && tree?.status?.isClean != false { return false }
            let repository = model.settings.repositories.first { $0.id == run.repositoryID }
            return model.search.isEmpty || [run.definition.name, tree?.displayName ?? "", repository?.name ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(model.search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("전체 실행 현황").font(.title2.bold())
                Spacer()
                Button("전체 중지", role: .destructive) { stopAll = true }
                    .disabled(!model.execution.hasActiveSession || model.execution.isStoppingAll)
            }
            HStack(spacing: 20) {
                Label("실행 \(model.execution.entries.filter { $0.session.isActive }.count)", systemImage: "play.circle")
                Label("준비 \(model.execution.pendingLaunchCount)", systemImage: "hourglass")
                Label("LISTEN \(Set(model.execution.entries.filter { $0.session.isActive }.flatMap(\.ports).map(\.id)).count)", systemImage: "network")
            }.font(.callout).foregroundStyle(.secondary)
            Picker("표시할 실행", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            List {
                let groups = displayedGroups
                if !groups.isEmpty {
                    Section("실행 그룹") {
                        ForEach(groups) { run in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(run.definition.name).fontWeight(.semibold)
                                    Spacer()
                                    if model.execution.groups.canStop(run, execution: model.execution) {
                                        Button("그룹 중지") {
                                            Task { do { try await model.execution.groups.stop(run, execution: model.execution) }
                                                catch { model.errorMessage = error.localizedDescription } }
                                        }
                                    }
                                }
                                let repository = model.settings.repositories.first { $0.id == run.repositoryID }
                                let tree = model.worktrees.first { $0.id == run.worktreeID }
                                Text("\(repository?.name ?? "—") › \(tree?.displayName ?? "—")").font(.caption).foregroundStyle(.secondary)
                                GroupRunDetails(model: model, run: run)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                ForEach(displayed) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: entry.task == nil ? "terminal" : "play.rectangle")
                        Text(entry.title).fontWeight(.semibold)
                        StatusBadge(status: entry.status).help(entry.resultDescription)
                        Spacer()
                        Button("출력 보기") { model.revealSession(entry, stayInActivity: true) }
                        Button("워크트리로 이동") { model.revealSession(entry) }
                        if entry.session.isActive {
                            Button("중지") {
                                Task { do { try await entry.session.stop() } catch { model.errorMessage = error.localizedDescription } }
                            }
                        }
                    }
                    let repository = model.settings.repositories.first { $0.id == entry.repositoryID }
                    let tree = model.worktrees.first { $0.id == entry.worktreeID }
                    Text("\(repository?.name ?? "—") › \(tree?.displayName ?? "—")").font(.callout)
                    Text(entry.session.configuration.directory.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                        if let end = entry.endedAt { Text(RunDuration.format(end.timeIntervalSince(entry.startedAt))).foregroundStyle(.secondary) }
                        ForEach(entry.ports) { port in
                            Menu("\(port.host):\(port.port)") {
                                Button("HTTP로 열기") { if let url = port.browserURL(scheme: "http") { model.openURL(url) } }
                                Button("HTTPS로 열기") { if let url = port.browserURL(scheme: "https") { model.openURL(url) } }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }
                    }.font(.caption)
                    if entry.status == .failed { Text(entry.resultDescription).font(.caption).foregroundStyle(.red) }
                }.padding(.vertical, 6)
                }
            }
            .overlay {
                if displayed.isEmpty && displayedGroups.isEmpty {
                    ContentUnavailableView("표시할 실행이 없습니다", systemImage: "play.rectangle",
                        description: Text("필터를 바꾸거나 워크트리에서 작업을 시작하세요."))
                }
            }
            Text("기록은 현재 앱 세션 기준입니다. 종료한 작업 탭은 최근 20개를 유지합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .alert("모든 실행을 중지할까요?", isPresented: $stopAll) {
            Button("전체 중지", role: .destructive) {
                Task { do { try await model.execution.stopEverything() } catch { model.errorMessage = error.localizedDescription } }
            }
            Button("취소", role: .cancel) {}
        } message: { Text("이 앱이 시작한 작업과 터미널을 함께 중지합니다.") }
    }
}
