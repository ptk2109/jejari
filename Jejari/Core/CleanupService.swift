import AppKit

/// 🧰 정리하기: 🧲 한 화면으로 모으기, 🧹 깨끗하게 비우기
enum CleanupService {
    /// 지울 수 있는 가상화면 수 (모니터마다 1번과 전체 화면 Space는 빼고)
    static func removableSpaceCount() -> Int {
        SpaceService.layout().reduce(0) { total, display in
            total + display.types.indices.dropFirst().filter { display.types[$0] != 4 }.count
        }
    }

    /// 모니터마다 1번만 남기고 가상화면을 지운다. 지운 화면의 창은 1번으로 모인다 (0단계 확인)
    static func collapseSpaces(progress: (String) -> Void) -> [String] {
        var log: [String] = []
        for display in DisplayService.current() {
            guard let layout = SpaceService.layout().first(where: { $0.displayUuid == display.uuid }), layout.ids.count > 1 else { continue }
            _ = SpaceService.switchTo(display: display.uuid, index: 1)
            let targets = (2...layout.ids.count).filter { layout.types[$0 - 1] != 4 }
            guard !targets.isEmpty else { continue }
            let removed = SpaceService.removeSpaces(display: display.uuid, screen: display.frame, indexes: targets)
            log.append("\(display.name): 가상화면 \(removed)개를 지우고 창을 1번 화면에 모음")
            progress(log.last!)
        }
        return log
    }

    /// 종료 요청 대상: 일반 앱 중 제자리 자신, Finder, 항상 건드리지 않을 앱은 뺀다
    static func quitTargets() -> [NSRunningApplication] {
        let keep = OtherAppsService.alwaysKeep
        return WindowService.regularApps().filter {
            guard let id = $0.bundleIdentifier else { return false }
            return id != "com.apple.finder" && !keep.contains(id)
        }
    }

    /// ⌘Q와 같은 정상 종료 요청. 저장 안 한 문서는 각 앱이 묻는다
    static func quit(_ apps: [NSRunningApplication]) -> [String] {
        apps.compactMap { app in
            app.terminate()
            return app.localizedName
        }
    }
}
