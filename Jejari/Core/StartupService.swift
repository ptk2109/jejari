import Foundation
import ServiceManagement

/// 로그인할 때 실행과 로그인 직후 자동 불러오기
enum StartupService {
    /// 로그인 항목 (시스템 설정 → 일반 → 로그인 항목에도 보인다)
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("로그인 항목 변경 실패: \(error)")
            }
        }
    }

    /// 사용자가 시스템 설정에서 허용해야 하는 상태
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// 로그인 직후 자동으로 불러올 배치 이름 (빈 문자열이면 안 함)
    static var autoLoadName: String {
        get { UserDefaults.standard.string(forKey: "autoLoadSnapshot") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "autoLoadSnapshot") }
    }

    /// 앱들이 뜰 시간을 기다렸다가 불러온다 (초)
    static var autoLoadDelay: Int {
        get { UserDefaults.standard.object(forKey: "autoLoadDelay") as? Int ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLoadDelay") }
    }

    /// 부팅 후 이 시간 안에 제자리가 시작됐을 때만 "로그인 직후"로 본다. 평소에 제자리를 다시 켤 때는 불러오지 않는다
    static let loginWindow: TimeInterval = 600

    static var launchedRightAfterLogin: Bool { ProcessInfo.processInfo.systemUptime < loginWindow }
}
