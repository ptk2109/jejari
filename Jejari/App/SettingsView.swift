import Combine
import SwiftUI

/// 설정 점검 화면 (기획서 13장). 권장값과 다른 항목을 보여 주고 바꿀 수 있는 것은 버튼으로 맞춘다
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(state.checks) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : (item.required ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(item.ok ? .green : (item.required ? .red : .orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(item.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    switch item.action {
                    case .fix: Button("권장대로") { apply(item) }
                    case .openSettings: Button("설정 열기") { apply(item) }
                    case .none: EmptyView()
                    }
                }
            }
            Divider()
            HStack {
                Text("시스템 설정이 열려 있으면 다시 열어야 바뀐 값이 보입니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("모두 권장대로") {
                    state.checks.filter { $0.action == .fix }.forEach(SettingsCheck.perform)
                    refreshSoon()
                }
                .disabled(!state.checks.contains { $0.action == .fix })
            }
        }
        .padding(20)
        .frame(width: 520)
        .onReceive(timer) { _ in state.checks = SettingsCheck.items() }
    }

    private func apply(_ item: CheckItem) {
        SettingsCheck.perform(item)
        refreshSoon()
    }

    /// 단축키·Dock 설정은 반영까지 1~2초 걸린다 (0단계)
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.checks = SettingsCheck.items() }
    }
}
