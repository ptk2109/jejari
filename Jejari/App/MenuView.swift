import SwiftUI

/// 메뉴바 메뉴 (기획서 2장)
struct MenuView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updates = UpdateService.shared

    var body: some View {
        Button("📸 현재 배치 저장…") { state.startSave() }
            .disabled(state.busy)

        Menu("📂 불러오기") {
            if state.snapshots.isEmpty {
                Text("저장된 배치 없음")
            }
            // 기획서 12.1: 스냅샷 ▸ ② 전체 복원(기본) / ① 배치만
            ForEach(state.snapshotNames, id: \.self) { name in
                Menu(name) {
                    Button("② 전체 복원 (앱 실행 포함)") { state.restore(name, mode: .full) }
                    Button("① 배치만 (열린 창만 옮기기, 불러올 때 설정 무시)") { state.restore(name, mode: .arrange) }
                }
            }
        }
        .disabled(state.busy)

        Button("↩️ 되돌리기") { state.undo() }
            .disabled(state.busy || !state.canUndo)

        Button("🗂 배치 관리…") { state.open(.manage) }

        Menu("🧰 정리하기") {
            Button("🧲 한 화면으로 모으기 (가상화면을 지우고 창을 한 곳에)") { state.collapse() }
            Button("🧹 깨끗하게 비우기 (가상화면을 지우고 앱 종료)") { state.wipe() }
        }
        .disabled(state.busy)

        Divider()

        if !state.status.isEmpty {
            Text(state.status)
        }
        Button("마지막 결과 보기") { state.open(.result) }
            .disabled(state.lastReport == nil)

        Divider()

        Button(state.needsAttention ? "⚠️ 설정… (확인 필요)" : "⚙️ 설정…") {
            state.reload()
            state.open(.settings)
        }
        if UpdateService.isAvailable {
            Button("업데이트 확인…") { UpdateService.shared.checkNow() }
                .disabled(!updates.canCheck)
        }

        Divider()

        Button("제자리 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
