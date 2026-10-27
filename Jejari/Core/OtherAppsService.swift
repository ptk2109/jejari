import AppKit

/// 스냅샷에 없는 앱 처리 (기획서 12.2 #4). 앱을 강제로 끄지 않는다: 종료는 ⌘Q와 같은 정상 종료 요청
enum OtherAppsService {
    /// 항상 건드리지 않을 앱 (기획서 12.6 제외 목록). 화면은 아직 없고 UserDefaults "alwaysKeepApps"
    static var alwaysKeep: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "alwaysKeepApps") ?? [])
    }

    /// 스냅샷에 없는 실행 중인 일반 앱. 제자리 자신과 제외 목록은 뺀다
    static func others(for snapshot: Snapshot) -> [NSRunningApplication] {
        let included = snapshot.includedBundleIds
        let keep = alwaysKeep
        return WindowService.regularApps().filter {
            guard let id = $0.bundleIdentifier else { return false }
            return !included.contains(id) && !keep.contains(id)
        }
    }

    /// 종료 요청 대상. Finder는 일반적인 방법으로 끄지 않으므로 뺀다
    static func quitTargets(for snapshot: Snapshot) -> [NSRunningApplication] {
        others(for: snapshot).filter { $0.bundleIdentifier != "com.apple.finder" }
    }

    /// 스냅샷에 포함된 앱이 숨겨져 있으면 다시 보이게 한다 (숨기기로 불러온 뒤 다른 배치를 불러올 때)
    static func unhideIncluded(_ snapshot: Snapshot) -> [String] {
        var shown: [String] = []
        for app in WindowService.regularApps() where snapshot.includedBundleIds.contains(app.bundleIdentifier ?? "") {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if (AX.attribute(element, kAXHiddenAttribute) as Bool?) == true {
                AX.setBool(element, kAXHiddenAttribute, false)  // NSRunningApplication.unhide()는 다른 앱에 false를 돌려줘서 AX로 (0단계)
                shown.append(app.localizedName ?? "?")
            }
        }
        return shown
    }

    /// 정책대로 처리하고 처리한 앱 이름을 돌려준다
    static func apply(_ policy: OtherAppsPolicy, for snapshot: Snapshot) -> [String] {
        switch policy {
        case .keep, .collect:
            return []  // 보관 화면으로 모으기는 Restorer가 창을 옮기며 처리
        case .hide:
            return others(for: snapshot).compactMap { app in
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AX.setBool(element, kAXHiddenAttribute, true)
                return app.localizedName
            }
        case .quit:
            return quitTargets(for: snapshot).compactMap { app in
                app.terminate()
                return app.localizedName
            }
        }
    }
}
