import SwiftUI
import UserNotifications

/// 메뉴바 상주 앱 (Dock 아이콘 없음: Info.plist LSUIElement)
@main
struct JejariApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            MenuBarIcon()
                .environmentObject(state)
        }

        Window("배치 저장", id: AppWindow.save.rawValue) {
            SaveView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)  // 메뉴바 앱: 실행할 때 창을 자동으로 열지 않는다
        .handlesExternalEvents(matching: [])  // jejari:// URL을 받을 때 SwiftUI가 이 창을 여는 것을 막음 (URL은 AppDelegate가 처리)

        Window("배치 창 고르기", id: AppWindow.edit.rawValue) {
            EditView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)  // 메뉴바 앱: 실행할 때 창을 자동으로 열지 않는다
        .handlesExternalEvents(matching: [])  // jejari:// URL을 받을 때 SwiftUI가 이 창을 여는 것을 막음 (URL은 AppDelegate가 처리)

        Window("배치 관리", id: AppWindow.manage.rawValue) {
            ManageView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)  // 메뉴바 앱: 실행할 때 창을 자동으로 열지 않는다
        .handlesExternalEvents(matching: [])  // jejari:// URL을 받을 때 SwiftUI가 이 창을 여는 것을 막음 (URL은 AppDelegate가 처리)

        Window("불러오기 결과", id: AppWindow.result.rawValue) {
            ResultView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)  // 메뉴바 앱: 실행할 때 창을 자동으로 열지 않는다
        .handlesExternalEvents(matching: [])  // jejari:// URL을 받을 때 SwiftUI가 이 창을 여는 것을 막음 (URL은 AppDelegate가 처리)

        Window("제자리 설정", id: AppWindow.settings.rawValue) {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)  // 메뉴바 앱: 실행할 때 창을 자동으로 열지 않는다
        .handlesExternalEvents(matching: [])  // jejari:// URL을 받을 때 SwiftUI가 이 창을 여는 것을 막음 (URL은 AppDelegate가 처리)
    }
}

/// 메뉴바 아이콘. 앱이 뜰 때 바로 그려지므로 여기서 창 여는 동작을 AppState에 넘긴다
private struct MenuBarIcon: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.busy ? "arrow.triangle.2.circlepath" : (state.needsAttention ? "exclamationmark.triangle" : "rectangle.3.group"))
            .onAppear { state.openWindowAction = openWindow }
    }
}

/// jejari:// URL 명령과 알림 클릭을 받는다
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // 로그인 직후면 고른 배치를 자동으로 불러온다 (앱들이 뜰 시간을 기다린 뒤)
        let name = StartupService.autoLoadName
        if !name.isEmpty && StartupService.launchedRightAfterLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(StartupService.autoLoadDelay)) {
                AppState.shared.restore(name, mode: .full)
            }
        }
    }

    /// URL 명령이나 Dock 아이콘 클릭 같은 "다시 열기"에 창을 열지 않는다.
    /// 열린 창이 없으면 SwiftUI가 첫 창(배치 저장)을 빈 채로 열어 버리기 때문 (메뉴바 앱)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { AppState.shared.handle(url) }
        }
    }

    /// 앱이 앞에 있어도 배너를 보여 준다
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 알림을 누르면 결과 창
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppState.shared.open(.result) }
    }
}
