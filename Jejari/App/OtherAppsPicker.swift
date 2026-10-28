import SwiftUI

/// 불러올 때 설정 (다른 앱 처리, 가상화면 맞추는 방식, 남는 가상화면 정리). 저장 창과 배치 관리 창이 같이 쓴다.
/// 선택지를 모두 펼쳐 놓고 쉬운 설명과 예시를 붙인다
struct OtherAppsPicker: View {
    @Binding var policy: OtherAppsPolicy
    @Binding var tidySpaces: Bool
    @Binding var strategy: SpaceStrategy

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("나중에 이 배치를 불러올 때 할 일").font(.title3).fontWeight(.semibold)
                Text("다음에 ② 전체 복원으로 불러올 때 어떻게 할지 미리 정해 두는 거예요. 저장할 창이나 위치와는 상관없어요. ① 배치만으로 불러오면 이 설정은 쓰이지 않아요.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OptionGroup(title: "배치에 없는 앱이 켜져 있으면?", selection: $policy,
                        about: "불러올 때, 이 배치에 저장하지 않은 앱이 켜져 있으면 그 앱을 어떻게 할지 정해요.\n예) '회사' 배치에는 Chrome과 엑셀만 저장했는데, 불러올 때 카카오톡도 켜져 있다면?",
                        notes: policyNotes, options: [
                (.keep, "그대로 둠", "그 앱은 손대지 않아요. 카카오톡 창은 있던 자리에 그대로 있어요."),
                (.collect, "보관 화면으로 모으기", "그 앱의 창을 맨 뒤 가상화면 하나에 몰아 둬요. 앱은 꺼지지 않아요. 카카오톡은 마지막 화면으로 비켜나요."),
                (.hide, "숨기기", "그 앱을 숨겨요(⌘H와 같아요). 그 앱이 들어 있는 배치를 불러오면 다시 보여요. 카카오톡이 눈앞에서 사라지지만 알림은 계속 와요."),
                (.quit, "종료 요청", "그 앱을 꺼요(⌘Q와 같아요). 끄기 전에 목록을 보여 주고 물어봐요. 저장하지 않은 문서는 각 앱이 따로 물어봐요. 퇴근할 때 업무 앱을 모두 끄고 싶을 때 좋아요."),
            ])

            OptionGroup(title: "가상화면을 어떻게 맞출까?", selection: $strategy,
                        about: "가상화면(트랙패드를 세 손가락으로 쓸어 올리면 위쪽에 보이는 데스크톱 1, 2, 3…)의 개수나 순서가 저장할 때와 달라졌을 수 있어요. 불러올 때 어떻게 맞출지 정해요. 빠른 방법과 정확한 방법 중에 고르는 거예요.",
                        options: [
                (.auto, "자동 (추천)", "알아서 골라요. 저장한 모니터가 없거나 가상화면이 크게 달라졌으면 모두 지웠다가 다시 만들고, 아니면 '필요한 것만'처럼 해요."),
                (.incremental, "필요한 것만", "지금 가상화면은 그대로 쓰고, 모자라면 더 만들기만 해요. 자리가 바뀐 창만 옮겨서 빨라요.\n예) 아침에 창 몇 개만 흐트러졌을 때."),
                (.reset, "초기화 후 다시 만들기", "가상화면을 모두 지웠다가 저장한 순서대로 다시 만들어요. 가장 정확하지만, 창이 많으면 1분쯤 걸리고 그동안 화면이 여러 번 바뀌어요.\n예) 모니터를 뺐다 꽂아서 화면 순서가 뒤바뀌었을 때."),
            ])

            // 초기화하면 화면을 스냅샷 수만큼만 다시 만들어 남는 화면이 생기지 않는다 → 비활성 (값은 그대로 두어 다른 방식으로 바꾸면 되살아남)
            OptionGroup(title: "가상화면이 저장할 때보다 많으면?", selection: $tidySpaces, disabled: strategy == .reset,
                        about: "불러온 뒤에 저장할 때보다 가상화면이 더 많으면, 남는 화면을 그대로 둘지 치울지 정해요.\n예) 저장할 땐 데스크톱 4개였는데 지금은 7개 → 5~7번을 어떻게 할까?",
                        notes: tidyNotes, options: [
                (false, "그대로 둠", "남는 화면과 그 안의 창을 손대지 않아요."),
                (true, "정리하기", "남는 화면에 있던 창은 화면 하나에 모으고, 빈 화면은 지워요. 5~7번의 창이 5번에 모이고 6·7번은 지워져요."),
            ])
        }
    }

    /// 다른 설정과의 관계 안내 (선택 조합에 따라)
    private var policyNotes: [String] {
        var notes: [String] = []
        if strategy == .reset && policy == .keep {
            notes.append("⚠️ 가상화면을 초기화하면 배치에 없는 앱의 창이 있던 화면도 지워져서, 그 창들은 1번 화면에 모여요. 따로 두려면 '보관 화면으로 모으기'를 고르세요.")
        }
        let keep = OtherAppsService.alwaysKeep.map(OtherAppsService.appName).sorted()
        if !keep.isEmpty {
            notes.append("항상 건드리지 않을 앱(\(keep.joined(separator: ", ")))은 여기서 빠져요. 설정 → 항상 건드리지 않을 앱에서 바꿀 수 있어요.")
        }
        return notes
    }

    private var tidyNotes: [String] {
        switch strategy {
        case .reset: return ["가상화면을 초기화하면 저장한 수만큼만 다시 만들어서 남는 화면이 생기지 않아요. 이 설정은 쓰이지 않아요."]
        case .auto: return ["'자동'이 '필요한 것만'을 고를 때만 적용돼요."]
                + (policy == .collect && !tidySpaces ? ["남는 화면의 창은 보관 화면으로 모이지만 빈 화면은 남아요. 빈 화면까지 지우려면 '정리하기'를 고르세요."] : [])
        case .incremental:
            return policy == .collect && !tidySpaces ? ["남는 화면의 창은 보관 화면으로 모이지만 빈 화면은 남아요. 빈 화면까지 지우려면 '정리하기'를 고르세요."] : []
        }
    }
}

/// 선택지를 모두 펼쳐 보여 주는 라디오 목록. 선택지마다 설명이 붙는다
struct OptionGroup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    var disabled = false
    /// 이 설정이 정하는 것과 예시 (제목 바로 아래)
    var about: String? = nil
    var notes: [String] = []
    let options: [(value: Value, title: String, detail: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let about {
                Text(about).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notes, id: \.self) { note in
                Text(note).font(.callout)
                    .foregroundStyle(note.hasPrefix("⚠️") ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .disabled(disabled)
            }
        }
        .opacity(disabled ? 0.45 : 1)
    }
}
