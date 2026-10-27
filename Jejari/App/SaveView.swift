import SwiftUI

/// 저장 확인 창 (기획서 12.6): 수집된 창을 모니터·가상화면별 체크박스로 보여 주고 포함할 것을 고른다
struct SaveView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let draft = state.draft {
                content(draft)
            } else {
                ProgressView("창을 모으는 중…")
                    .frame(width: 560, height: 200)
            }
        }
        .onDisappear { state.cancelDraft() }
    }

    private func content(_ draft: Snapshot) -> some View {
        let names = Dictionary(uniqueKeysWithValues: draft.displays.map { ($0.uuid, $0.name) })
        // (모니터, 가상화면 번호)별로 묶는다. 모니터는 주 모니터부터
        let order = draft.displays.sorted { $0.isMain && !$1.isMain }.map(\.uuid)
        let groups = Dictionary(grouping: draft.windows.indices) { "\(draft.windows[$0].displayUuid)#\(draft.windows[$0].spaceIndex)" }
            .sorted { a, b in
                let wa = draft.windows[a.value[0]], wb = draft.windows[b.value[0]]
                let da = order.firstIndex(of: wa.displayUuid) ?? 99, db = order.firstIndex(of: wb.displayUuid) ?? 99
                return da != db ? da < db : wa.spaceIndex < wb.spaceIndex
            }
        let selected = draft.windows.count - state.excludedWindows.count
        let exists = state.snapshotNames.contains(state.draftName.trimmingCharacters(in: .whitespaces))

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("이름")
                TextField("예: 회사 기본", text: $state.draftName)
                    .textFieldStyle(.roundedBorder)
            }
            if exists {
                Text("같은 이름의 배치를 덮어씁니다.").font(.caption).foregroundStyle(.orange)
            }

            List {
                ForEach(groups, id: \.key) { _, indexes in
                    let first = draft.windows[indexes[0]]
                    Section("\(names[first.displayUuid] ?? "모니터") · 가상화면 \(first.spaceIndex)") {
                        ForEach(indexes, id: \.self) { index in
                            Toggle(isOn: include(index)) {
                                HStack {
                                    Text(draft.windows[index].appName)
                                    Text(draft.windows[index].title).foregroundStyle(.secondary).lineLimit(1)
                                    if draft.windows[index].minimized { Text("최소화").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                if !state.draftWindowlessApps.isEmpty {
                    Section("창 없이 실행 중인 앱") {
                        ForEach(state.draftWindowlessApps, id: \.bundleId) { app in
                            Toggle(app.name, isOn: includeApp(app.bundleId))
                        }
                    }
                }
            }
            .frame(minHeight: 320)

            HStack {
                Text("창 \(selected)/\(draft.windows.count)개").foregroundStyle(.secondary)
                Spacer()
                Button("취소") { state.cancelDraft(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { state.commitDraft(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.draftName.trimmingCharacters(in: .whitespaces).isEmpty || selected == 0)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    private func include(_ index: Int) -> Binding<Bool> {
        Binding(get: { !state.excludedWindows.contains(index) },
                set: { if $0 { state.excludedWindows.remove(index) } else { state.excludedWindows.insert(index) } })
    }

    private func includeApp(_ bundleId: String) -> Binding<Bool> {
        Binding(get: { !state.excludedApps.contains(bundleId) },
                set: { if $0 { state.excludedApps.remove(bundleId) } else { state.excludedApps.insert(bundleId) } })
    }
}
