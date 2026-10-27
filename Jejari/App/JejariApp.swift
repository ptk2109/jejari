import SwiftUI

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
            Image(systemName: state.needsAttention ? "exclamationmark.triangle" : "rectangle.3.group")
        }

        Window("제자리 설정 점검", id: "settings") {
            SettingsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

/// jejari:// URL 명령을 받는다
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { AppState.shared.handle(url) }
        }
    }
}
