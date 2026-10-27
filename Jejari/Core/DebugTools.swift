#if DEBUG
import AppKit

/// 개발 빌드 전용: 복원을 시험하려고 창 몇 개를 일부러 흐트러뜨린다 (jejari://scramble)
enum DebugTools {
    /// 지금 대화 중인 터미널 등은 건드리지 않는다
    static let untouchable: Set<String> = ["com.stablyai.orca"]

    static func scramble() -> [String] {
        var log: [String] = []
        let displays = DisplayService.current()
        guard let main = displays.first(where: \.isMain) else { return ["주 모니터 없음"] }
        let layout = SpaceService.layout()
        var candidates: [(name: String, window: LiveWindow, display: String, index: Int)] = []
        for app in WindowService.regularApps() where !untouchable.contains(app.bundleIdentifier ?? "") {
            for window in WindowService.scan(pid: app.processIdentifier).windows {
                guard (AX.attribute(window.element, "AXFullScreen") as Bool?) != true,
                      let location = SpaceService.location(of: window.windowID, in: layout) else { continue }
                candidates.append(("\(app.localizedName ?? "?") \"\(window.title.prefix(30))\"", window, location.display, location.index))
            }
        }
        candidates.sort { $0.name < $1.name }
        var used = Set<CGWindowID>()
        func take(_ condition: (String, Int) -> Bool) -> (name: String, window: LiveWindow, display: String, index: Int)? {
            guard let found = candidates.first(where: { !used.contains($0.window.windowID) && condition($0.display, $0.index) }) else { return nil }
            used.insert(found.window.windowID)
            return found
        }

        // 1) 다른 모니터에 있는 창을 주 모니터로
        if let item = take({ display, _ in display != main.uuid }) {
            AX.setPosition(item.window.element, CGPoint(x: main.frame.minX + 60, y: main.frame.minY + 60))
            log.append("\(item.name): \(item.display.prefix(8)) #\(item.index) → 주 모니터")
        }
        // 2) Space가 2개 이상인 모니터에서 다른 Space로 (다른 모니터를 거쳐 돌아옴)
        if let item = take({ display, _ in (layout.first { $0.displayUuid == display }?.ids.count ?? 0) >= 2 }),
           let count = layout.first(where: { $0.displayUuid == item.display })?.ids.count,
           let other = displays.first(where: { $0.uuid != item.display }) {
            let target = item.index == 1 ? 2 : 1
            let original = item.window.frame
            if SpaceService.switchTo(display: item.display, index: target) {
                AX.setPosition(item.window.element, CGPoint(x: other.frame.minX + 50, y: other.frame.minY + 50))
                usleep(300_000)
                AX.setPosition(item.window.element, original.origin)
                log.append("\(item.name): #\(item.index) → #\(target) (Space \(count)개 중)")
            }
        }
        // 3) 크기와 위치 바꾸기
        if let item = take({ _, _ in true }) {
            let f = item.window.frame
            AX.setPosition(item.window.element, CGPoint(x: f.minX + 80, y: f.minY + 80))
            AX.setSize(item.window.element, CGSize(width: f.width * 0.7, height: f.height * 0.7))
            log.append("\(item.name): 위치 +80, 크기 70%")
        }
        // 4) 최소화
        if let item = take({ _, _ in true }) {
            AX.setBool(item.window.element, kAXMinimizedAttribute, true)
            log.append("\(item.name): 최소화")
        }
        return log
    }
}
#endif
