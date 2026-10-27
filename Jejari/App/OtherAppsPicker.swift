import SwiftUI

/// 불러올 때 설정 (다른 앱 처리, 가상화면 맞추는 방식, 남는 가상화면 정리). 저장 창과 배치 관리 창이 같이 쓴다.
/// 선택지를 모두 펼쳐 놓고 쉬운 설명과 예시를 붙인다
struct OtherAppsPicker: View {
    @Binding var policy: OtherAppsPolicy
    @Binding var tidySpaces: Bool
    @Binding var strategy: SpaceStrategy

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("이 설정은 ② 전체 복원으로 불러올 때 적용돼요. ① 배치만은 열린 창만 옮겨요.")
                .font(.callout).foregroundStyle(.secondary)

            OptionGroup(title: "이 배치에 없는 앱은?", selection: $policy, options: [
                (.keep, "그대로 둠", "다른 앱은 손대지 않아요.\n예) 회사 배치를 불러와도 켜 둔 음악 앱은 그대로."),
                (.collect, "보관 화면으로 모으기", "다른 앱 창을 맨 뒤 가상화면 하나에 몰아 둬요. 꺼지지는 않아요.\n예) 회사 배치를 불러오면 개인 앱 창은 마지막 화면으로 비켜나요."),
                (.hide, "숨기기", "다른 앱을 숨겨요(⌘H). 다른 배치를 불러오면 다시 보여요.\n예) 집에서 '휴식' 배치를 불러오면 업무 앱이 눈앞에서 사라져요."),
                (.quit, "종료 요청", "다른 앱을 종료해요(⌘Q). 불러오기 전에 목록을 보여 주고 물어봐요. 저장 안 한 문서는 각 앱이 물어봐요.\n예) 퇴근할 때 '집' 배치로 업무 앱을 모두 끌 때."),
            ])

            OptionGroup(title: "가상화면은 어떻게 맞출까?", selection: $strategy, options: [
                (.auto, "자동 (추천)", "알아서 골라요. 모니터가 바뀌었거나 화면 순서가 뒤죽박죽이면 새로 만들고, 아니면 자리가 바뀐 창만 옮겨요."),
                (.incremental, "필요한 것만", "지금 가상화면은 그대로 두고 자리가 바뀐 창만 옮겨요. 빨라요.\n예) 아침에 창 몇 개만 흐트러졌을 때."),
                (.reset, "초기화 후 다시 만들기", "가상화면을 모두 지웠다가 저장한 순서대로 다시 만들어요. 가장 정확하지만 창이 많으면 1분쯤 걸리고 화면이 여러 번 바뀌어요.\n예) 모니터를 뺐다 꽂아서 화면 순서가 뒤바뀌었을 때."),
            ])

            OptionGroup(title: "남는 가상화면은?", selection: $tidySpaces, options: [
                (false, "그대로 둠", "저장할 때보다 가상화면이 많아도 손대지 않아요."),
                (true, "정리하기", "저장한 화면 뒤에 남는 가상화면이 있으면, 그 안의 창은 화면 하나에 모으고 빈 화면은 지워요.\n예) 회사 모니터를 빼서 노트북 가상화면이 13개로 늘었을 때 깔끔하게."),
            ])
        }
    }
}

/// 선택지를 모두 펼쳐 보여 주는 라디오 목록. 선택지마다 설명이 붙는다
struct OptionGroup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String, detail: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title).fontWeight(selected ? .semibold : .regular)
                            Text(option.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
