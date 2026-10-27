import SwiftUI

/// 스냅샷 관리: 목록, 불러오기, 이름 바꾸기, 삭제
struct ManageView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var renameError: String?
    @State private var deleting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.snapshots.isEmpty {
                ContentUnavailableView("저장된 배치 없음", systemImage: "rectangle.3.group",
                                       description: Text("메뉴의 \"현재 배치 저장…\"으로 지금 배치를 저장하세요."))
            } else {
                List(state.snapshots, selection: $selection) { snapshot in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.name).font(.headline)
                        Text(detail(snapshot)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(snapshot.name)
                    .contextMenu { actions(for: snapshot.name) }
                }
            }
            HStack {
                Button("불러오기") { if let selection { state.restore(selection) } }
                    .disabled(selection == nil || state.busy)
                Button("이름 바꾸기") { if let selection { startRename(selection) } }
                    .disabled(selection == nil)
                Button("삭제", role: .destructive) { deleting = selection }
                    .disabled(selection == nil)
                Spacer()
                Button("폴더 열기") {
                    try? FileManager.default.createDirectory(at: SnapshotStore.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SnapshotStore.directory)
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 400)
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
        return "\(date) · 창 \(snapshot.windows.count)개 · 모니터 \(snapshot.displays.count)대 · 가상화면 \(spaces)개"
    }
}
