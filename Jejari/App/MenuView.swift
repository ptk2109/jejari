import SwiftUI

/// 메뉴바 메뉴 (기획서 2장)
struct MenuView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("📸 현재 배치 저장…") { state.promptSave() }
            .disabled(state.busy)

        Menu("📂 불러오기") {
            if state.snapshotNames.isEmpty {
                Text("저장된 배치 없음")
            }
            ForEach(state.snapshotNames, id: \.self) { name in
                Button(name) { state.restore(name) }
            }
        }
        .disabled(state.busy)

        Button("↩️ 되돌리기") { state.undo() }
            .disabled(state.busy || !state.canUndo)

        Divider()

        if !state.status.isEmpty {
            Text(state.status)
        }
        Button("마지막 결과 보기") { state.showReport() }
            .disabled(state.lastReport == nil)

        Divider()

        Button(state.needsAttention ? "⚠️ 설정 점검…" : "⚙️ 설정 점검…") {
            state.reload()
            openWindow(id: "settings")
            NSApp.activate()
        }
        Button("스냅샷 폴더 열기") {
            try? FileManager.default.createDirectory(at: SnapshotStore.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(SnapshotStore.directory)
        }

        Divider()

        Button("제자리 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
