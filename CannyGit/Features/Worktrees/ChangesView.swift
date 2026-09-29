import SwiftUI

struct ChangesView: View {
    @Bindable var model: DashboardModel
    let tree: Worktree
    @State private var selectedPath: String?
    @State private var scope: DiffScope = .working
    @State private var document: DiffDocument?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = UUID()

    private var selectedFile: GitFileChange? { tree.status?.files.first { $0.path == selectedPath } }
    private var request: String {
        "\(tree.id):\(selectedPath ?? ""):\(scope.rawValue):\(tree.status?.collectedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("미추적 파일 확장", isOn: Binding(
                    get: { model.expandedUntracked.contains(tree.id) },
                    set: { value in Task { await model.refreshStatus(tree.id, expandUntracked: value) } }
                )).toggleStyle(.checkbox).disabled(!tree.canExecute)
                Spacer()
                Text("읽기 전용").font(.caption).foregroundStyle(.secondary)
            }
            VSplitView {
                List(selection: $selectedPath) {
                    ForEach(tree.status?.files ?? []) { file in
                        HStack(alignment: .top) {
                            Text(verbatim: file.isConflict ? "UU" : String([file.index, file.workingTree]))
                                .font(.caption.monospaced()).foregroundStyle(file.isConflict ? .red : .orange)
                            VStack(alignment: .leading) {
                                Text(file.path)
                                if let original = file.originalPath { Text("← \(original)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.tag(file.path)
                    }
                }.frame(minHeight: 80, idealHeight: 140)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Diff 영역", selection: $scope) {
                            ForEach(DiffScope.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 250)
                        if loading { ProgressView().controlSize(.small) }
                        Spacer()
                        if let selectedPath { Button("경로 복사") { model.copyPath(selectedPath) } }
                    }
                    if let file = selectedFile { Text(file.path).font(.caption.monospaced()).textSelection(.enabled) }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if let notice = document?.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if selectedFile != nil, let document, !document.text.isEmpty {
                        DiffTextView(text: document.text, highlighted: selectedFile?.isUntracked != true)
                    } else {
                        ContentUnavailableView(selectedFile == nil ? "파일 선택" : "표시할 diff가 없습니다",
                            systemImage: "doc.text.magnifyingglass")
                    }
                }.frame(minHeight: 150)
            }
        }
        .padding(12)
        .onChange(of: selectedPath) { _, _ in
            document = nil
            if let file = selectedFile { scope = file.workingTree == "." && !file.isUntracked ? .staged : .working }
        }
        .onChange(of: scope) { _, _ in document = nil; error = nil }
        .onChange(of: tree.status?.files.map(\.path)) { _, paths in
            if let selectedPath, !(paths ?? []).contains(selectedPath) { self.selectedPath = nil; document = nil }
        }
        .task(id: request) {
            guard let selectedFile else { return }
            let token = UUID()
            generation = token
            loading = true
            defer { if generation == token { loading = false } }
            do {
                let result = try await model.git.diff(worktree: tree, file: selectedFile, scope: scope, executable: model.settings.gitPath)
                guard !Task.isCancelled, generation == token else { return }
                document = result
                error = nil
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, generation == token else { return }
                document = nil
                self.error = error.localizedDescription
            }
        }
    }
}

struct DiffTextView: NSViewRepresentable {
    let text: String
    let highlighted: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.isEditable = false
        view.isSelectable = true
        view.usesFindBar = true
        view.isRichText = false
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.setAccessibilityIdentifier("diffContent")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let selection = view.selectedRange(), origin = scroll.contentView.bounds.origin
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        if highlighted {
            let string = text as NSString
            var location = 0
            while location < string.length {
                let range = string.lineRange(for: NSRange(location: location, length: 0))
                let line = string.substring(with: range)
                let color: NSColor?
                if line.hasPrefix("@@") { color = .systemBlue }
                else if line.hasPrefix("+") && !line.hasPrefix("+++") { color = .systemGreen }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { color = .systemRed }
                else { color = nil }
                if let color { attributed.addAttribute(.foregroundColor, value: color, range: range) }
                location = NSMaxRange(range)
            }
        }
        view.textStorage?.setAttributedString(attributed)
        view.setSelectedRange(NSRange(location: min(selection.location, attributed.length), length: 0))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
