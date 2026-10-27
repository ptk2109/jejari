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

        Window("배치 관리", id: AppWindow.manage.rawValue) {
            ManageView().environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("불러오기 결과", id: AppWindow.result.rawValue) {
            ResultView().environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("제자리 설정 점검", id: AppWindow.settings.rawValue) {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentSize)
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
    }

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
