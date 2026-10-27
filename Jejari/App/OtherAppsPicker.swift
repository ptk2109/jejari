import SwiftUI

/// 다른 앱 처리 선택 (기획서 12.2 #4). 저장 창과 배치 관리 창이 같이 쓴다
struct OtherAppsPicker: View {
    @Binding var policy: OtherAppsPolicy
    @Binding var tidySpaces: Bool
    @Binding var strategy: SpaceStrategy

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("이 배치에 없는 앱")
            Picker("", selection: $policy) {
                ForEach(OtherAppsPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
        }
        Text(explanation).font(.caption).foregroundStyle(.secondary)
        Toggle("남는 가상화면 정리 (필요한 화면 뒤의 창은 보관 화면 하나로 모으고 빈 화면은 지움)", isOn: $tidySpaces)
            .font(.callout)
        HStack(alignment: .firstTextBaseline) {
            Text("가상화면 맞추는 방식")
            Picker("", selection: $strategy) {
                ForEach(SpaceStrategy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
        }
        Text(strategyExplanation).font(.caption).foregroundStyle(.secondary)
    }

    private var strategyExplanation: String {
        switch strategy {
        case .auto: "모니터 구성이 다르거나 화면이 뒤죽박죽이면 초기화하고, 아니면 필요한 것만 옮깁니다."
        case .incremental: "지금 가상화면을 살리고 다른 창만 옮깁니다. 빠릅니다."
        case .reset: "1번만 남기고 가상화면을 지워 모든 창을 모은 뒤 순서대로 다시 만듭니다. 정확하지만 모든 창을 옮겨서 느립니다."
        }
    }

    private var explanation: String {
        switch policy {
        case .keep: "② 전체 복원 때 다른 앱은 건드리지 않습니다."
        case .collect: "② 전체 복원 때 다른 앱의 창을 모니터마다 보관 화면(필요한 화면 뒤 가상화면 하나)으로 모읍니다."
        case .hide: "② 전체 복원 때 다른 앱을 숨깁니다(⌘H). 다른 배치를 불러오면 다시 보입니다."
        case .quit: "② 전체 복원 때 다른 앱에 종료를 요청합니다(⌘Q). 불러오기 전에 목록을 보여 주고 확인합니다."
        }
    }
}
