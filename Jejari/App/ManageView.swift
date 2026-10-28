import SwiftUI

/// 배치 관리. 왼쪽은 목록 전체에 대한 일(체크, 여러 개 삭제), 오른쪽은 고른 배치 하나에 대한 일
/// (이름, 불러오기, 창 고르기, 복제, 불러올 때 설정). 이름과 설정은 고친 뒤 [저장]으로 반영한다
struct ManageView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?
    /// 여러 개 지우기용 체크 (행을 고르는 selection과 따로)
    @State private var checked = Set<String>()
    @State private var deletingNames: [String] = []
    /// 오른쪽에서 고치는 중인 값. [저장]을 눌러야 파일에 반영된다
    @State private var editName = ""
    @State private var editPolicy: OtherAppsPolicy = .keep
    @State private var editTidy = false
    @State private var editStrategy: SpaceStrategy = .auto
    @State private var notice = ""

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            listPane.frame(width: 340)
            Divider()
            detailPane
        }
        .padding(20)
        .frame(width: 1040, height: 780)
        .onAppear { state.reload(); load(selection) }
        // 다른 배치를 고르면: 저장 안 한 변경은 앞서 고른 배치에 자동 저장하고 새 배치를 불러온다
        .onChange(of: selection) { old, new in
            if let old, isDirty(for: old), nameProblem(for: old) == nil {
                save(old)
                notice = "\"\(trimmedName)\" 바뀐 내용을 저장했어요"
            } else {
                notice = ""
            }
            load(new)
        }
        .onChange(of: state.snapshotNames) { _, names in
            checked.formIntersection(names)
            if let selection, !names.contains(selection) { self.selection = nil }
        }
        .alert("배치 \(deletingNames.count)개를 삭제할까요?", isPresented: Binding(get: { !deletingNames.isEmpty }, set: { if !$0 { deletingNames = [] } })) {
            Button("삭제", role: .destructive) {
                for name in deletingNames { state.delete(name) }
                checked.subtract(deletingNames)
                deletingNames = []
            }
            Button("취소", role: .cancel) { deletingNames = [] }
        } message: {
            Text(deletingNames.sorted().joined(separator: "\n") + "\n\n삭제한 배치는 되돌릴 수 없어요.")
        }
    }

    // MARK: 왼쪽: 목록

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.snapshots.isEmpty {
                ContentUnavailableView("저장된 배치 없음", systemImage: "rectangle.3.group",
                                       description: Text("메뉴의 \"📸 현재 배치 저장…\"으로 지금 배치를 저장하세요."))
            } else {
                Toggle(isOn: Binding(get: { checked.count == state.snapshots.count },
                                     set: { checked = $0 ? Set(state.snapshotNames) : [] })) {
                    Text(checked.isEmpty ? "모두 선택" : "\(checked.count)개 체크됨").font(.callout)
                }
                List(state.snapshots, selection: $selection) { snapshot in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { checked.contains(snapshot.name) },
                                                 set: { if $0 { checked.insert(snapshot.name) } else { checked.remove(snapshot.name) } }))
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name).font(.headline)
                            Text(snapshot.createdAt.listStamp).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(snapshot.name)
                    .contextMenu {
                        Button("② 전체 복원으로 불러오기") { state.restore(snapshot.name, mode: .full) }
                        Button("① 배치만 불러오기 (설정 무시)") { state.restore(snapshot.name, mode: .arrange) }
                        Button("창 고르기…") { state.startEdit(snapshot.name) }
                        Button("복제") { selection = state.duplicate(snapshot.name) ?? snapshot.name }
                        Divider()
                        Button("삭제…", role: .destructive) { deletingNames = [snapshot.name] }
                    }
                }
            }
            Divider()
            HStack {
                Button("🗑 체크한 \(checked.count)개 삭제", role: .destructive) { deletingNames = checked.sorted() }
                    .disabled(checked.isEmpty)
                Spacer()
                Button("폴더 열기") {
                    try? FileManager.default.createDirectory(at: SnapshotStore.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SnapshotStore.directory)
                }
            }
        }
    }

    // MARK: 오른쪽: 고른 배치

    @ViewBuilder
    private var detailPane: some View {
        if let selection, let snapshot = current(selection) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("이름").font(.headline)
                    TextField("배치 이름", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                }
                Text(summary(snapshot)).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Menu {
                        Button("② 전체 복원 (앱 실행 포함)") { state.restore(selection, mode: .full) }
                        Button("① 배치만 (열린 창만 옮기기, 불러올 때 설정 무시)") { state.restore(selection, mode: .arrange) }
                    } label: {
                        Text("▶ 불러오기")
                    } primaryAction: {
                        state.restore(selection, mode: .full)
                    }
                    .fixedSize()
                    .disabled(state.busy)
                    Button("창 고르기…") { state.startEdit(selection) }
                    Button("복제") { self.selection = state.duplicate(selection) ?? selection }
                }
                Divider()
                ScrollView {
                    OtherAppsPicker(policy: $editPolicy, tidySpaces: $editTidy, strategy: $editStrategy)
                        .padding(.trailing, 8)
                }
                Divider()
                HStack {
                    if let problem = nameProblem(for: selection) {
                        Text(problem).font(.callout).foregroundStyle(.red)
                    } else if isDirty(for: selection) {
                        Text("바뀐 내용이 있어요").font(.callout).foregroundStyle(.orange)
                    } else if !notice.isEmpty {
                        Text(notice).font(.callout).foregroundStyle(.green)
                    }
                    Spacer()
                    Button("취소") { load(selection); notice = "" }
                        .disabled(!isDirty(for: selection))
                    Button("저장") {
                        save(selection)
                        notice = "저장했어요"
                    }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty(for: selection) || nameProblem(for: selection) != nil)
                }
            }
        } else {
            Text("왼쪽에서 배치를 고르면 이름과 불러올 때 설정을 바꿀 수 있어요.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 편집 값

    private func current(_ name: String?) -> Snapshot? { state.snapshots.first { $0.name == name } }

    private func load(_ name: String?) {
        guard let snapshot = current(name) else { return }
        editName = snapshot.name
        editPolicy = snapshot.otherAppsPolicy
        editTidy = snapshot.tidySpaces ?? false
        editStrategy = snapshot.spaceStrategy ?? .auto
    }

    private var trimmedName: String { editName.trimmingCharacters(in: .whitespaces) }

    private func isDirty(for name: String) -> Bool {
        guard let snapshot = current(name) else { return false }
        return trimmedName != snapshot.name || editPolicy != snapshot.otherAppsPolicy
            || editTidy != (snapshot.tidySpaces ?? false) || editStrategy != (snapshot.spaceStrategy ?? .auto)
    }

    /// 이름을 저장할 수 없는 이유
    private func nameProblem(for name: String) -> String? {
        if trimmedName.isEmpty { return "이름을 입력해 주세요" }
        if trimmedName == SnapshotStore.previousStateName { return "\"\(trimmedName)\"은 제자리가 쓰는 이름이에요" }
        if trimmedName != name && state.snapshotNames.contains(trimmedName) { return "같은 이름의 배치가 있어요" }
        return nil
    }

    /// 설정을 먼저 저장하고, 이름이 바뀌었으면 이름을 바꾼다
    private func save(_ name: String) {
        state.saveSettings(name, policy: editPolicy, tidySpaces: editTidy, strategy: editStrategy)
        let newName = trimmedName
        if newName != name, state.rename(name, to: newName) == nil, selection == name {
            selection = newName
        }
    }

    private func summary(_ snapshot: Snapshot) -> String {
        let date = snapshot.createdAt.listStamp
        let spaces = snapshot.spaces.reduce(0) { $0 + $1.spaces.count }
        let windows = snapshot.includedWindows.count == snapshot.windows.count ? "\(snapshot.windows.count)" : "\(snapshot.includedWindows.count)/\(snapshot.windows.count)"
        return "\(date) 저장 · 창 \(windows)개 · 모니터 \(snapshot.displays.count)대 · 가상화면 \(spaces)개"
    }
}

extension Date {
    /// 배치 목록에 보일 저장 시각: 2026-10-28 09:19 (언어 설정과 상관없이 같은 모양, 24시간)
    var listStamp: String { Self.listStampFormatter.string(from: self) }

    private static let listStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
