#if DEBUG
import AppKit

/// 개발 빌드 전용: 복원을 시험하려고 창 몇 개를 일부러 흐트러뜨린다 (jejari://scramble)
enum DebugTools {
    /// 지금 대화 중인 터미널 등은 건드리지 않는다
    static let untouchable: Set<String> = ["com.stablyai.orca"]

    static func drag(appQuery: String, to index: Int) -> [String] {
        var log: [String] = []
        guard let app = WindowService.regularApps().first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(appQuery.lowercased()) }),
              let window = WindowService.scan(pid: app.processIdentifier).windows.first,
              let location = SpaceService.location(of: window.windowID) else { return ["앱/창 없음"] }
        log.append("\(app.localizedName ?? "?") \"\(window.title.prefix(30))\" #\(location.index) → #\(index)")
        let ok = SpaceService.moveByDrag(element: window.element, windowID: window.windowID, display: location.display, to: index) { log.append("   \($0)") }
        log.append(ok ? "성공" : "실패")
        return log
    }

    /// 가상 모니터를 만들어 앱의 첫 창을 그 모니터를 거쳐 다른 Space로 옮긴다 (jejari://debugvd?app=…&to=…)
    static func virtualBounce(appQuery: String, to index: Int) -> [String] {
        var log: [String] = []
        guard let app = WindowService.regularApps().first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(appQuery.lowercased()) }),
              let window = WindowService.scan(pid: app.processIdentifier).windows.first,
              let from = SpaceService.location(of: window.windowID) else { return ["앱/창 없음"] }
        log.append("\(app.localizedName ?? "?") \"\(window.title.prefix(30))\" #\(from.index) → #\(index)")
        let original = AX.frame(window.element)
        let t0 = Date()
        guard let virtual = VirtualDisplay() else { return log + ["가상 모니터를 만들지 못함"] }
        log.append(String(format: "가상 모니터 생성 %.1f초: id %d, %@, 위치 %@", Date().timeIntervalSince(t0), virtual.displayID, virtual.uuid ?? "?", "\(virtual.frame)"))
        log.append("모니터 목록: \(DisplayService.current().map { "\($0.name) \($0.frame)" })")
        log.append("Space: \(SpaceService.layout().map { "\($0.displayUuid.prefix(8)) \($0.ids.count)개" })")
        let switched = SpaceService.switchTo(display: from.display, index: index)
        log.append("목표 #\(index)로 전환: \(switched)")
        AX.setPosition(window.element, CGPoint(x: virtual.frame.minX + 40, y: virtual.frame.minY + 40))
        usleep(400_000)
        log.append("가상 모니터로 보낸 뒤: \(SpaceService.location(of: window.windowID).map { "\($0.display.prefix(8)) #\($0.index)" } ?? "?")")
        AX.setPosition(window.element, original.origin)
        AX.setSize(window.element, original.size)
        usleep(400_000)
        let after = SpaceService.location(of: window.windowID)
        log.append("되돌린 뒤: \(after.map { "\($0.display.prefix(8)) #\($0.index)" } ?? "?"), 위치 \(AX.frame(window.element).origin)")
        let t1 = Date()
        virtual.remove()
        log.append(String(format: "가상 모니터 제거 %.1f초, 남은 모니터 %d대, Space %@", Date().timeIntervalSince(t1), DisplayService.current().count,
                          "\(SpaceService.layout().map { "\($0.displayUuid.prefix(8)) \($0.ids.count)개" })"))
        log.append("최종: \(SpaceService.location(of: window.windowID).map { "#\($0.index)" } ?? "?") \(after?.index == index ? "성공" : "실패")")
        return log
    }

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
        // 2) Space가 2개 이상인 모니터에서 다른 Space로 (다른 모니터를 거쳐 돌아옴, 모니터가 1대면 끌어서)
        if let item = take({ display, _ in (layout.first { $0.displayUuid == display }?.ids.count ?? 0) >= 2 }),
           let count = layout.first(where: { $0.displayUuid == item.display })?.ids.count {
            let target = item.index == 1 ? 2 : 1
            let original = item.window.frame
            if let other = displays.first(where: { $0.uuid != item.display }) {
                if SpaceService.switchTo(display: item.display, index: target) {
                    AX.setPosition(item.window.element, CGPoint(x: other.frame.minX + 50, y: other.frame.minY + 50))
                    usleep(300_000)
                    AX.setPosition(item.window.element, original.origin)
                    log.append("\(item.name): #\(item.index) → #\(target) (Space \(count)개 중)")
                }
            } else if let virtual = VirtualDisplay() {
                // 모니터가 1대면 임시 가상 모니터를 거쳐 옮긴다
                if SpaceService.switchTo(display: item.display, index: target) {
                    AX.setPosition(item.window.element, CGPoint(x: virtual.frame.minX + 40, y: virtual.frame.minY + 40))
                    usleep(400_000)
                    AX.setPosition(item.window.element, original.origin)
                    log.append("\(item.name): #\(item.index) → #\(target) (임시 모니터 경유, Space \(count)개 중)")
                }
                virtual.remove()
            } else {
                log.append("\(item.name): 임시 모니터를 만들지 못함")
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
