import SwiftUI

/// 스냅샷의 창을 모니터·가상화면별 체크박스로 보여 준다. 저장 확인 창과 배치 편집 창이 같이 쓴다 (기획서 12.6)
struct WindowChecklist: View {
    @Binding var snapshot: Snapshot

    var body: some View {
        let names = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ($0.uuid, $0.name) })
        List {
            ForEach(groups(), id: \.key) { group in
                let first = snapshot.windows[group.indexes[0]]
                Section {
                    ForEach(group.indexes, id: \.self) { index in
                        Toggle(isOn: $snapshot.windows[index].isIncluded) {
                            HStack {
                                Text(snapshot.windows[index].appName)
                                Text(snapshot.windows[index].title).foregroundStyle(.secondary).lineLimit(1)
                                if snapshot.windows[index].minimized { Text("최소화").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(names[first.displayUuid] ?? "모니터") · 가상화면 \(first.spaceIndex)")
                        Spacer()
                        Button(group.indexes.allSatisfy { snapshot.windows[$0].isIncluded } ? "모두 빼기" : "모두 포함") {
                            let all = group.indexes.allSatisfy { snapshot.windows[$0].isIncluded }
                            for index in group.indexes { snapshot.windows[index].isIncluded = !all }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            let windowless = snapshot.windowlessAppIndexes
            if !windowless.isEmpty {
                Section("창 없이 실행 중인 앱") {
                    ForEach(windowless, id: \.self) { index in
                        Toggle(snapshot.apps[index].name, isOn: $snapshot.apps[index].isIncluded)
                    }
                }
            }
        }
    }

    /// (모니터, 가상화면 번호)별로 묶는다. 모니터는 주 모니터부터
    private func groups() -> [(key: String, indexes: [Int])] {
        let order = snapshot.displays.sorted { $0.isMain && !$1.isMain }.map(\.uuid)
        return Dictionary(grouping: snapshot.windows.indices) { "\(snapshot.windows[$0].displayUuid)#\(snapshot.windows[$0].spaceIndex)" }
            .map { (key: $0.key, indexes: $0.value) }
            .sorted { a, b in
                let wa = snapshot.windows[a.indexes[0]], wb = snapshot.windows[b.indexes[0]]
                let da = order.firstIndex(of: wa.displayUuid) ?? 99, db = order.firstIndex(of: wb.displayUuid) ?? 99
                return da != db ? da < db : wa.spaceIndex < wb.spaceIndex
            }
    }
}

/// 체크박스 목록 아래의 개수 표시
struct ChecklistCount: View {
    let snapshot: Snapshot
    var body: some View {
        Text("창 \(snapshot.includedWindows.count)/\(snapshot.windows.count)개 포함").foregroundStyle(.secondary)
    }
}
