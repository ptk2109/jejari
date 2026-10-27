import SwiftUI

/// 스냅샷 관리: 목록, 불러오기, 이름 바꾸기, 삭제
struct ManageView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var renameError: String?
    @State private var deleting: String?
    /// 여러 개 지우기용 체크 (행을 고르는 selection과 따로)
    @State private var checked = Set<String>()
    @State private var deletingChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 왼쪽: 배치 목록, 오른쪽: 고른 배치의 불러올 때 설정
            HStack(alignment: .top, spacing: 20) {
                Group {
                    if state.snapshots.isEmpty {
                        ContentUnavailableView("저장된 배치 없음", systemImage: "rectangle.3.group",
                                               description: Text("메뉴의 \"현재 배치 저장…\"으로 지금 배치를 저장하세요."))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(get: { !state.snapshots.isEmpty && checked.count == state.snapshots.count },
                                                 set: { checked = $0 ? Set(state.snapshots.map(\.name)) : [] })) {
                                Text(checked.isEmpty ? "모두 선택" : "\(checked.count)개 체크됨").font(.callout)
                            }
                            List(state.snapshots, selection: $selection) { snapshot in
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("", isOn: Binding(get: { checked.contains(snapshot.name) },
                                                             set: { if $0 { checked.insert(snapshot.name) } else { checked.remove(snapshot.name) } }))
                                        .labelsHidden()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(snapshot.name).font(.headline)
                                        Text(detail(snapshot)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .tag(snapshot.name)
                                .contextMenu { actions(for: snapshot.name) }
                            }
                        }
                    }
                }
                .frame(width: 380)
                ScrollView {
                    if let selection, let snapshot = state.snapshots.first(where: { $0.name == selection }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\"\(selection)\" 불러올 때").font(.title3.bold())
                            OtherAppsPicker(policy: Binding(get: { snapshot.otherAppsPolicy }, set: { state.setOtherApps(selection, $0) }),
                                            tidySpaces: Binding(get: { snapshot.tidySpaces ?? false }, set: { state.setTidySpaces(selection, $0) }),
                                            strategy: Binding(get: { snapshot.spaceStrategy ?? .auto }, set: { state.setSpaceStrategy(selection, $0) }))
                        }
                        .padding(.trailing, 8)
                    } else {
                        Text("왼쪽에서 배치를 고르면 불러올 때 설정을 바꿀 수 있어요.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
            }
            HStack {
                Button("불러오기") { if let selection { state.restore(selection) } }
                    .disabled(selection == nil || state.busy)
                Button("창 고르기…") { if let selection { state.startEdit(selection) } }
                    .disabled(selection == nil)
                Button("복제") { if let selection { self.selection = state.duplicate(selection) ?? selection } }
                    .disabled(selection == nil)
                Button("이름 바꾸기") { if let selection { startRename(selection) } }
                    .disabled(selection == nil)
                Button("삭제", role: .destructive) { deleting = selection }
                    .disabled(selection == nil)
                Divider().frame(height: 16)
                Button("체크한 \(checked.count)개 삭제", role: .destructive) { deletingChecked = true }
                    .disabled(checked.isEmpty)
                Spacer()
                Button("폴더 열기") {
                    try? FileManager.default.createDirectory(at: SnapshotStore.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SnapshotStore.directory)
                }
            }
        }
        .padding(20)
        .frame(width: 1000, height: 760)
        .onAppear { state.reload() }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("새 이름", text: $newName)
            Button("바꾸기") {
                if let renaming { renameError = state.rename(renaming, to: newName); selection = renameError == nil ? newName : renaming }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
        .alert(renameError ?? "", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("확인") { renameError = nil }
        }
        .alert("체크한 배치 \(checked.count)개를 삭제할까요?", isPresented: $deletingChecked) {
            Button("삭제", role: .destructive) {
                for name in checked { state.delete(name) }
                if let selection, checked.contains(selection) { self.selection = nil }
                checked = []
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(checked.sorted().joined(separator: "\n") + "\n\n삭제한 배치는 되돌릴 수 없어요.")
        }
        .onChange(of: state.snapshotNames) { _, names in checked.formIntersection(names) }
        .confirmationDialog("\"\(deleting ?? "")\"을(를) 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("삭제", role: .destructive) {
                if let deleting { state.delete(deleting); selection = nil }
                deleting = nil
            }
        }
    }

    @ViewBuilder
    private func actions(for name: String) -> some View {
        Button("불러오기") { state.restore(name) }
        Button("창 고르기…") { state.startEdit(name) }
        Button("복제") { selection = state.duplicate(name) ?? name }
        Button("이름 바꾸기") { startRename(name) }
        Button("삭제", role: .destructive) { deleting = name }
    }

    private func startRename(_ name: String) {
        newName = name
        renaming = name
    }

    private func detail(_ snapshot: Snapshot) -> String {
        let date = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
        let spaces = snapshot.spaces.reduce(0) { $0 + $1.spaces.count }
        let windows = snapshot.includedWindows.count == snapshot.windows.count ? "\(snapshot.windows.count)" : "\(snapshot.includedWindows.count)/\(snapshot.windows.count)"
        let others = (snapshot.otherAppsPolicy == .keep ? "" : " · 다른 앱 \(snapshot.otherAppsPolicy.title)") + (snapshot.tidySpaces == true ? " · 가상화면 정리" : "")
        return "\(date) · 창 \(windows)개 · 모니터 \(snapshot.displays.count)대 · 가상화면 \(spaces)개\(others)"
    }
}
