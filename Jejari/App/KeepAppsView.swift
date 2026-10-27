import SwiftUI

/// 항상 건드리지 않을 앱 (기획서 12.6 제외 목록). 숨기기·종료 요청·보관 화면으로 모으기에서 빠진다
struct KeepAppsView: View {
    @State private var keep: [String] = OtherAppsService.alwaysKeep.sorted()
    @State private var candidate = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("항상 건드리지 않을 앱").font(.headline)
            Text("배치에 없더라도 숨기거나 종료하거나 보관 화면으로 옮기지 않습니다.").font(.callout).foregroundStyle(.secondary)
            ForEach(keep, id: \.self) { bundleId in
                HStack {
                    Text(OtherAppsService.appName(bundleId))
                    Text(bundleId).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("빼기") { update(keep.filter { $0 != bundleId }) }
                }
            }
            HStack {
                Picker("", selection: $candidate) {
                    Text("실행 중인 앱에서 고르기").tag("")
                    ForEach(runningCandidates, id: \.bundleId) { Text($0.name).tag($0.bundleId) }
                }
                .labelsHidden()
                Button("추가") { update(keep + [candidate]); candidate = "" }
                    .disabled(candidate.isEmpty)
            }
        }
    }

    private var runningCandidates: [(bundleId: String, name: String)] {
        WindowService.regularApps()
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !keep.contains($0.0) }
            .sorted { $0.1 < $1.1 }
            .map { (bundleId: $0.0, name: $0.1) }
    }

    private func update(_ list: [String]) {
        OtherAppsService.alwaysKeep = Set(list)
        keep = OtherAppsService.alwaysKeep.sorted()
    }
}
