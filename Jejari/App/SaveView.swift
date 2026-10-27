import SwiftUI

/// 저장 확인 창 (기획서 12.6): 수집된 창을 체크박스로 보여 주고 포함할 것을 고른다.
/// 뺀 창도 표시만 해서 저장하므로 나중에 배치 관리에서 다시 포함할 수 있다
struct SaveView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let draft = state.draft {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("이름").font(.headline)
                        TextField("예: 회사 기본, 집 휴식", text: $state.draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        if state.snapshotNames.contains(state.draftName.trimmingCharacters(in: .whitespaces)) {
                            Text("같은 이름의 배치를 덮어써요.").font(.callout).foregroundStyle(.orange)
                        }
                    }
                    // 왼쪽: 불러올 때 설정, 오른쪽: 포함할 창
                    HStack(alignment: .top, spacing: 20) {
                        ScrollView {
                            OtherAppsPicker(policy: Binding(get: { state.draft?.otherAppsPolicy ?? .keep }, set: { state.draft?.otherAppsPolicy = $0 }),
                                            tidySpaces: Binding(get: { state.draft?.tidySpaces ?? false }, set: { state.draft?.tidySpaces = $0 ? true : nil }),
                                            strategy: Binding(get: { state.draft?.spaceStrategy ?? .auto }, set: { state.draft?.spaceStrategy = $0 == .auto ? nil : $0 }))
                                .padding(.trailing, 8)
                        }
                        .frame(width: 470)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("저장할 창").font(.headline)
                            Text("체크를 끈 창은 불러올 때 건드리지 않아요. 나중에 배치 관리에서 다시 켤 수 있어요.")
                                .font(.callout).foregroundStyle(.secondary)
                            WindowChecklist(snapshot: Binding(get: { state.draft ?? draft }, set: { state.draft = $0 }))
                        }
                    }
                    HStack {
                        ChecklistCount(snapshot: draft)
                        Spacer()
                        Button("취소") { state.cancelDraft(); dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("저장") { state.commitDraft(); dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(state.draftName.trimmingCharacters(in: .whitespaces).isEmpty || draft.includedWindows.isEmpty)
                    }
                }
                .padding(20)
                .frame(width: 1080, height: 760)
            } else {
                ProgressView("창을 모으는 중…")
                    .frame(width: 1080, height: 200)
            }
        }
        .onDisappear { state.cancelDraft() }
    }
}

/// 저장된 배치의 포함할 창을 다시 고른다
struct EditView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let editing = state.editing {
                VStack(alignment: .leading, spacing: 12) {
                    Text(editing.name).font(.title3.bold())
                    Text("체크를 끈 창은 불러올 때 건드리지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    WindowChecklist(snapshot: Binding(get: { state.editing ?? editing }, set: { state.editing = $0 }))
                        .frame(minHeight: 320)
                    HStack {
                        ChecklistCount(snapshot: editing)
                        Spacer()
                        Button("취소") { state.editing = nil; dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("저장") { state.commitEdit(); dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(editing.includedWindows.isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 560, height: 520)
            } else {
                Text("편집할 배치가 없습니다").frame(width: 560, height: 200)
            }
        }
        .onDisappear { state.editing = nil }
    }
}
