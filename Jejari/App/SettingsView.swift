import Combine
import SwiftUI

/// 제자리 설정: 일반(로그인 시 실행, 자동 불러오기, 기록), 권한과 macOS 설정(기획서 13장), 항상 건드리지 않을 앱.
/// 항목마다 쉬운 설명과 예시를 붙인다
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("일반", systemImage: "gearshape") }
            ChecksSettings()
                .tabItem { Label(state.needsAttention ? "권한과 macOS 설정 ⚠️" : "권한과 macOS 설정", systemImage: "checkmark.shield") }
            ScrollView { KeepAppsView().padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                .tabItem { Label("항상 건드리지 않을 앱", systemImage: "hand.raised") }
        }
        .frame(width: 760, height: 680)
    }
}

// MARK: 일반

private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var launchAtLogin = StartupService.launchAtLogin
    @State private var autoLoadName = StartupService.autoLoadName
    @State private var autoLoadDelay = StartupService.autoLoadDelay
    @State private var logging = RunLogStore.isEnabled
    @State private var externalCommands = AppState.allowsExternalCommands
    @ObservedObject private var updates = UpdateService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                OptionGroup(title: "로그인할 때 제자리를 켤까요?", selection: Binding(get: { launchAtLogin }, set: { on in
                    StartupService.launchAtLogin = on
                    launchAtLogin = StartupService.launchAtLogin
                }), notes: loginNotes, options: [
                    (false, "켜지 않음", "필요할 때 직접 제자리를 실행해요."),
                    (true, "로그인할 때 켜기 (추천)", "맥을 켜고 로그인하면 제자리가 메뉴바에 자동으로 떠요. 시스템 설정 → 일반 → 로그인 항목에도 보여요.\n예) 아침에 맥을 켜자마자 메뉴바에서 바로 불러오기."),
                ])

                VStack(alignment: .leading, spacing: 8) {
                    Text("로그인한 뒤 배치를 자동으로 불러올까요?").font(.headline)
                    Text("맥을 켜고 로그인하면 고른 배치를 ② 전체 복원으로 불러와요. 앱이 뜰 시간을 기다렸다가 시작해요. 부팅 후 10분 안에 제자리가 켜질 때만 동작해서, 평소에 제자리를 다시 켤 때는 불러오지 않아요.\n예) 회사에 도착해 맥을 켜면 PhpStorm, 브라우저, 메신저가 늘 쓰던 모니터와 가상화면에 알아서 놓여요.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !launchAtLogin {
                        Text("⚠️ '로그인할 때 켜기'를 먼저 골라야 동작해요.").font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("불러올 배치")
                        Picker("", selection: $autoLoadName) {
                            Text("불러오지 않음").tag("")
                            ForEach(state.snapshotNames, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                        .onChange(of: autoLoadName) { _, new in StartupService.autoLoadName = new }
                    }
                    HStack {
                        Text("로그인 후 기다릴 시간")
                        Stepper("\(autoLoadDelay)초", value: $autoLoadDelay, in: 5...120, step: 5)
                            .onChange(of: autoLoadDelay) { _, new in StartupService.autoLoadDelay = new }
                        Text("앱이 많거나 느리게 뜨면 늘리세요.").font(.callout).foregroundStyle(.secondary)
                    }
                    .disabled(autoLoadName.isEmpty)
                }

                OptionGroup(title: "불러오기 기록을 남길까요?", selection: Binding(get: { logging }, set: { on in
                    RunLogStore.isEnabled = on
                    logging = on
                }), options: [
                    (false, "남기지 않기 (추천)", "기록 없이 불러와요. 결과는 '마지막 결과 보기'에서 볼 수 있어요."),
                    (true, "남기기", "불러올 때마다 직전 상태, 결과, 불러온 뒤 상태를 이 맥에 최근 20개까지 남겨요. 창 제목, 문서 경로, 탭 주소가 들어가고 1~2초 더 걸려요. 어디에도 보내지 않아요.\n예) 불러오기가 이상할 때 켜고 한 번 더 불러온 뒤, [기록 폴더 열기]로 폴더를 보내 문제를 알려 주세요."),
                ])
                Button("기록 폴더 열기") {
                    try? FileManager.default.createDirectory(at: RunLogStore.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(RunLogStore.directory)
                }

                OptionGroup(title: "새 버전이 나오면?", selection: Binding(get: { updates.mode }, set: { updates.mode = $0 }),
                            disabled: !UpdateService.isAvailable, notes: updateNotes, options: [
                    (.notify, "알려 주기 (추천)", "하루에 한 번 새 버전이 있는지 확인하고, 있으면 무엇이 바뀌었는지 보여 줘요. [설치]를 누르면 받아서 다시 켜요.\n예) 아침에 \"제자리 0.3.0이 나왔어요\" 창이 뜨면 바뀐 내용을 읽고 설치."),
                    (.install, "알아서 설치", "새 버전을 조용히 받아 두었다가 제자리를 끌 때(맥을 끌 때 포함) 바꿔 둬요. 묻지 않아요."),
                    (.off, "확인하지 않음", "메뉴의 '업데이트 확인…'을 누를 때만 확인해요."),
                ])
                Button("지금 확인") { UpdateService.shared.checkNow() }
                    .disabled(!updates.canCheck)

                OptionGroup(title: "다른 앱이나 스크립트가 제자리를 부를 수 있게 할까요?", selection: Binding(get: { externalCommands }, set: { on in
                    AppState.allowsExternalCommands = on
                    externalCommands = AppState.allowsExternalCommands
                }), disabled: AppState.isDevBuild, notes: AppState.isDevBuild ? ["⚠️ 개발 빌드는 시험용으로 항상 허용하고, 확인 창도 띄우지 않아요."] : [], options: [
                    (false, "허용 안 함 (추천)", "제자리는 메뉴에서만 써요. 웹페이지나 다른 앱이 jejari:// 주소로 배치를 불러오거나 저장할 수 없어요."),
                    (true, "허용", "단축어, 스크립트, 다른 앱이 jejari://restore?name=회사 같은 주소로 불러오기·저장·되돌리기를 부를 수 있어요. 가상화면을 지우거나 앱을 끄는 명령은 그래도 매번 확인 창을 띄워요.\n예) 단축어 앱의 '회사 와이파이에 연결되면' 자동화로 회사 배치 불러오기."),
                ])
            }
            .padding(20)
        }
        .onAppear {
            launchAtLogin = StartupService.launchAtLogin
            autoLoadName = StartupService.autoLoadName
        }
    }

    private var updateNotes: [String] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var notes = ["지금 버전: \(version)"]
        if !UpdateService.isAvailable {
            notes.append("⚠️ 개발 빌드는 업데이트를 확인하지 않아요.")
        }
        return notes
    }

    private var loginNotes: [String] {
        var notes: [String] = []
        if StartupService.needsApproval {
            notes.append("⚠️ 시스템 설정 → 일반 → 로그인 항목에서 제자리를 허용해 주세요.")
        }
        if !Bundle.main.bundlePath.hasPrefix("/Applications") {
            notes.append("⚠️ 제자리가 응용 프로그램 폴더 밖(\(Bundle.main.bundlePath))에서 실행 중이에요. 이 위치를 옮기면 로그인 항목이 동작하지 않아요.")
        }
        return notes
    }
}

// MARK: 권한과 macOS 설정

private struct ChecksSettings: View {
    @EnvironmentObject private var state: AppState
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("제자리가 창을 읽고 옮기려면 필요한 권한과 macOS 설정이에요. ⚠️가 있으면 [권장대로]나 [설정 열기]를 눌러 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(state.checks) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : (item.required ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                            .foregroundStyle(item.ok ? .green : (item.required ? .red : .orange))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let example = Self.examples[item.id] {
                                Text(example).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        switch item.action {
                        case .fix: Button("권장대로") { apply(item) }
                        case .openSettings: Button("설정 열기") { apply(item) }
                        case .none: EmptyView()
                        }
                    }
                    .padding(10)
                    .background(item.ok ? Color.clear : Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                HStack {
                    Text("시스템 설정이 열려 있으면 닫았다가 다시 열어야 바뀐 값이 보여요.")
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
        }
        .onReceive(timer) { _ in state.refreshChecks() }
    }

    /// 항목별 예시
    static let examples: [String: String] = [
        "accessibility": "예) 이 권한이 없으면 저장도 불러오기도 할 수 없어요. 처음 한 번만 켜면 돼요.",
        "skylight": "예) macOS를 업데이트한 뒤 여기가 ⚠️면 가상화면 기능이 막힌 거예요. 위치와 크기는 그대로 복원돼요.",
        "mru": "예) 켜져 있으면 Dock에서 앱을 누를 때마다 가상화면 순서가 바뀌어서, 저장한 '3번 화면'이 다른 화면이 돼요.",
        "hotkeys": "예) 창을 5번 가상화면으로 옮길 때 '데스크톱 5로 전환'을 써요. 꺼져 있으면 해당 가상화면으로 못 옮겨요.",
        "separate": "예) 꺼져 있으면 모든 모니터가 가상화면을 함께 넘겨서, 모니터마다 다른 화면을 둘 수 없어요.",
    ]

    private func apply(_ item: CheckItem) {
        SettingsCheck.perform(item)
        refreshSoon()
    }

    /// 단축키·Dock 설정은 반영까지 1~2초 걸린다 (0단계)
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.refreshChecks() }
    }
}
