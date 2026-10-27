import AppKit
import CoreGraphics

/// 모니터 하나의 현재 Space 구성
struct LiveDisplaySpaces {
    let displayUuid: String
    let ids: [UInt64]          // ManagedSpaceID (부팅마다 바뀜)
    let uuids: [String]        // Space uuid (재부팅 후에도 유지, 0단계)
    let types: [Int]
    let currentID: UInt64

    var currentIndex: Int? { ids.firstIndex(of: currentID).map { $0 + 1 } }
}

/// Space 조회와 이동. 공개 API가 없어서 비공개 SkyLight + 단축키(⌃N) + Mission Control AX를 쓴다 (기획서 5장, 0단계)
enum SpaceService {
    /// 데스크톱 N으로 전환 단축키 id = 117 + N (1~16)
    static let desktopHotKeyRange: ClosedRange<Int32> = 118...133

    static func layout() -> [LiveDisplaySpaces] {
        SkyLight.managedDisplaySpaces().map { display in
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            return LiveDisplaySpaces(
                displayUuid: display["Display Identifier"] as? String ?? "",
                ids: spaces.map { $0["ManagedSpaceID"] as? UInt64 ?? 0 },
                uuids: spaces.map { $0["uuid"] as? String ?? "" },
                types: spaces.map { $0["type"] as? Int ?? -1 },
                currentID: (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64 ?? 0)
        }
    }

    /// 창이 있는 (모니터 UUID, 모니터 안 번호). 최소화/숨김 창도 Space를 유지한다 (0단계)
    static func location(of windowID: CGWindowID, in layout: [LiveDisplaySpaces]? = nil) -> (display: String, index: Int)? {
        guard let id = SkyLight.spaces(for: windowID).first else { return nil }
        for display in layout ?? self.layout() {
            if let i = display.ids.firstIndex(of: id) { return (display.displayUuid, i + 1) }
        }
        return nil
    }

    static func currentIndex(of display: String) -> Int? {
        layout().first { $0.displayUuid == display }?.currentIndex
    }

    /// ⌃N 번호는 모니터를 넘어 이어지는 전역 번호 (앞 모니터들의 Space 수 + 모니터 안 번호, 0단계)
    static func globalNumber(display: String, index: Int) -> Int? {
        var offset = 0
        for item in layout() {
            if item.displayUuid == display { return offset + index }
            offset += item.ids.count
        }
        return nil
    }

    /// 단축키 id(symbolic hotkey)를 사용자가 설정한 키 조합 그대로 보낸다
    private static func press(hotKey id: Int32) -> Bool {
        guard SkyLight.hotKeyEnabled(id), let key = SkyLight.hotKeyValue(id) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: UInt64(key.modifiers))
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        return true
    }

    private static func waitFor(display: String, index: Int) -> Bool {
        let start = Date()
        while currentIndex(of: display) != index && Date().timeIntervalSince(start) < 2 { usleep(50_000) }
        usleep(250_000)  // 전환 애니메이션 마무리
        return currentIndex(of: display) == index
    }

    /// Space를 전환하고 바뀔 때까지 기다린다. 데스크톱 N 단축키(1~16)로 바로 가고,
    /// 16번을 넘거나 그 단축키가 꺼져 있으면 왼쪽/오른쪽 Space 이동(⌃←/⌃→, id 79/81)으로 한 칸씩 간다
    @discardableResult
    static func switchTo(display: String, index: Int) -> Bool {
        if currentIndex(of: display) == index { return true }
        if let number = globalNumber(display: display, index: index), desktopHotKeyRange.contains(Int32(117 + number)),
           press(hotKey: Int32(117 + number)) {
            return waitFor(display: display, index: index)
        }
        // 한 칸씩: ⌃←/⌃→는 마우스가 있는 모니터에 적용되므로 마우스를 그 모니터로 옮긴다 (0단계)
        guard let screen = DisplayService.current().first(where: { $0.uuid == display })?.frame else { return false }
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: screen.midX, y: screen.midY), mouseButton: .left)?.post(tap: .cghidEventTap)
        for _ in 0..<24 {
            guard let current = currentIndex(of: display) else { return false }
            if current == index { return true }
            guard press(hotKey: index > current ? 81 : 79), waitFor(display: display, index: current + (index > current ? 1 : -1)) else { return false }
        }
        return currentIndex(of: display) == index
    }

    /// 지금 Space 수에 필요한 데스크톱 단축키 중 꺼진 것. 앱이 켠 11~16은 재부팅마다 꺼진다 (0단계)
    static func disabledDesktopHotKeys() -> [Int32] {
        let total = min(layout().reduce(0) { $0 + $1.ids.count }, 16)
        guard total > 0 else { return [] }
        return (1...total).map { Int32(117 + $0) }.filter { !SkyLight.hotKeyEnabled($0) }
    }

    static func enableDesktopHotKeys() {
        for id in disabledDesktopHotKeys() { SkyLight.setHotKey(id, enabled: true) }
    }

    // MARK: 모니터가 1대일 때 Space 이동 (0단계 방법 B)

    nonisolated(unsafe) private static let mouseSource = CGEventSource(stateID: .hidSystemState)

    /// 실제 클릭처럼 클릭 횟수(clickState = 1)를 채워서 보낸다. 0이면 창 끌기가 시작되지 않는 앱이 있다
    private static func postMouse(_ type: CGEventType, _ point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: mouseSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    /// 창 제목 표시줄을 마우스로 잡은 채 ⌃N으로 Space를 바꿔 창을 옮긴다. 거쳐 갈 다른 모니터가 없을 때 쓴다.
    /// 잡는 곳: 창 맨 위 4pt, 신호등 버튼 오른쪽 (Chrome은 그 아래가 탭 줄이라 탭을 끌어내지 않도록 맨 위만)
    /// 창을 끌어도 안전한 제목 표시줄 지점을 찾는다. 제목 표시줄 높이에서 왼쪽부터 짚어 보며
    /// 버튼·탭·입력칸처럼 눌러서 동작하는 요소가 없고 그 창에 속한 빈 곳인 첫 지점.
    /// 맨 위 몇 pt는 크기 조절 가장자리라 잡히지 않는다. Chrome 탭을 잡으면 탭이 떨어져 나가고, JetBrains는 프로젝트 버튼이 눌린다
    static func dragPoint(window: AXUIElement, frame: CGRect) -> CGPoint? {
        let system = AXUIElementCreateSystemWide()
        let interactive: Set<String> = [kAXButtonRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole,
                                        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXLink", kAXSliderRole, kAXIncrementorRole,
                                        kAXMenuBarItemRole, kAXDisclosureTriangleRole, "AXTab", "AXSearchField"]
        for dy: CGFloat in [12, 9, 16] {
            for x in stride(from: frame.minX + 80, to: frame.maxX - 40, by: 24) {
                let point = CGPoint(x: x, y: frame.minY + dy)
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { continue }
                // 이 창의 요소인지 (다른 창이 덮고 있으면 건너뜀)
                let owner: AXUIElement? = (AX.attribute(hit, kAXRoleAttribute) as String?) == kAXWindowRole ? hit : AX.attribute(hit, kAXWindowAttribute)
                guard let owner, CFEqual(owner, window) else { continue }
                let role: String = AX.attribute(hit, kAXRoleAttribute) ?? ""
                var actions: CFArray?
                AXUIElementCopyActionNames(hit, &actions)
                let pressable = (actions as? [String] ?? []).contains(kAXPressAction)
                if !interactive.contains(role) && !pressable { return point }
            }
        }
        return nil
    }

    static func moveByDrag(element: AXUIElement, windowID: CGWindowID, display: String, to index: Int, log: ((String) -> Void)? = nil) -> Bool {
        guard let from = location(of: windowID), from.display == display else { log?("창 위치를 모름"); return false }
        guard switchTo(display: display, index: from.index) else { log?("창이 있는 #\(from.index)로 전환 실패"); return false }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        usleep(200_000)
        let frame = AX.frame(element)
        guard let grab = dragPoint(window: element, frame: frame) else { log?("제목 표시줄에서 잡을 빈 곳을 찾지 못함"); return false }
        let saved = CGEvent(source: nil)?.location ?? .zero
        defer { postMouse(.mouseMoved, saved) }
        postMouse(.mouseMoved, grab); usleep(150_000)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        log?("커서 이동 확인: 목표 \(Int(grab.x)),\(Int(grab.y)) / 실제 \(Int(cursor.x)),\(Int(cursor.y))")
        postMouse(.leftMouseDown, grab); usleep(300_000)
        // 손으로 끄는 것처럼 천천히 30pt
        for dx in stride(from: 2, through: 30, by: 2) { postMouse(.leftMouseDragged, CGPoint(x: grab.x + CGFloat(dx), y: grab.y)); usleep(40_000) }
        usleep(200_000)
        let dragged = AX.frame(element)
        log?("잡기 \(Int(grab.x)),\(Int(grab.y)) → 창이 \(Int(dragged.minX - frame.minX))pt 따라옴 (30이면 잡힘)")
        let held = CGPoint(x: grab.x + 30, y: grab.y)
        let switched = switchTo(display: display, index: index)
        log?("잡은 채 #\(index)로 전환: \(switched ? "성공" : "실패"), 지금 #\(currentIndex(of: display) ?? -1)")
        postMouse(.leftMouseDragged, held); usleep(200_000)
        for dx in stride(from: 28, through: 0, by: -2) { postMouse(.leftMouseDragged, CGPoint(x: grab.x + CGFloat(dx), y: grab.y)); usleep(30_000) }
        postMouse(.leftMouseUp, grab)
        usleep(400_000)
        let after = location(of: windowID)
        log?("놓은 뒤 창 #\(after?.index ?? -1)")
        return switched && after.map { $0.display == display && $0.index == index } == true
    }

    // MARK: Mission Control로 Space 추가/삭제
    // macOS 27에서 Mission Control UI는 Dock이 아니라 WindowManager 프로세스의 AX 트리에 있다 (0단계)

    private static var windowManager: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func missionControlOpen() -> Bool {
        guard let windowManager else { return false }
        return !AX.find(windowManager, identifier: "mc.display").isEmpty
    }

    private static func pressEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    /// Mission Control을 열고 해당 모니터 영역에서 작업한 뒤, 어떤 경우에도 닫는다
    private static func withMissionControl(screen: CGRect, log: ((String) -> Void)? = nil, _ body: (AXUIElement) -> Void) -> Bool {
        guard let windowManager else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        defer { if missionControlOpen() { pressEscape(); usleep(800_000) } }
        var region: AXUIElement?
        let start = Date()
        while region == nil && Date().timeIntervalSince(start) < 3 {
            usleep(200_000)
            region = AX.find(windowManager, identifier: "mc.display").first { AX.frame($0) == screen }
        }
        log?("mc.display \(AX.find(windowManager, identifier: "mc.display").map { "\(AX.frame($0))" }), 대상 \(screen) → \(region == nil ? "못 찾음" : "찾음")")
        guard let region else { return false }
        // 위쪽 Spaces 막대를 펼친다 (접혀 있으면 썸네일에 삭제 동작이 없다. 0단계에서 펼친 상태로 성공)
        let savedMouse = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: screen.midX, y: screen.minY + 3), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(800_000)
        defer {
            CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                    mouseCursorPosition: savedMouse, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        body(region)
        return true
    }

    /// 모니터에 Space를 count개 추가하고 실제로 늘어난 수를 돌려준다
    static func addSpaces(display: String, screen: CGRect, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let before = layout().first { $0.displayUuid == display }?.ids.count ?? 0
        _ = withMissionControl(screen: screen) { region in
            guard let add = AX.find(region, identifier: "mc.spaces.add").first else { return }
            for _ in 0..<count {
                AXUIElementPerformAction(add, kAXPressAction as CFString)
                usleep(500_000)
            }
            usleep(500_000)
        }
        return (layout().first { $0.displayUuid == display }?.ids.count ?? 0) - before
    }

    /// 모니터 안 번호(1부터)의 Space들을 삭제한다. 뒤 번호부터 지운다
    static func removeSpaces(display: String, screen: CGRect, indexes: [Int], log: ((String) -> Void)? = nil) -> Int {
        var removed = 0
        _ = withMissionControl(screen: screen, log: log) { region in
            for index in indexes.sorted(by: >) {
                guard let list = AX.find(region, identifier: "mc.spaces.list").first else { log?("mc.spaces.list 없음"); break }
                let thumbnails: [AXUIElement] = AX.attribute(list, kAXChildrenAttribute) ?? []
                if let t = thumbnails.indices.contains(index - 1) ? thumbnails[index - 1] : nil {
                    var actions: CFArray?
                    AXUIElementCopyActionNames(t, &actions)
                    log?("썸네일 \(thumbnails.count)개, #\(index) \(AX.attribute(t, kAXTitleAttribute) as String? ?? "") 동작 \(actions as? [String] ?? [])")
                }
                guard index >= 1, index <= thumbnails.count else { continue }
                if AXUIElementPerformAction(thumbnails[index - 1], "AXRemoveDesktop" as CFString) == .success { removed += 1 }
                usleep(600_000)
            }
        }
        return removed
    }

    // MARK: 시스템 설정 값

    /// "최근 사용 내역에 따라 자동으로 Spaces 재정렬". 켜져 있으면 Space 순서가 저절로 바뀐다 (기획서 13장)
    static var autoRearrangeEnabled: Bool {
        (UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "mru-spaces") as? Bool) ?? true
    }

    /// 값을 쓰고 Dock을 재시작해야 반영된다 (약 0.6초, 창 배치 영향 없음, 0단계)
    static func setAutoRearrange(_ enabled: Bool) {
        CFPreferencesSetAppValue("mru-spaces" as CFString, enabled as CFBoolean, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").forEach { $0.terminate() }
    }

    /// "디스플레이마다 별도 Spaces". 바꾸면 로그아웃해야 적용되므로 읽기만 한다
    static var separateSpacesPerDisplay: Bool {
        !((UserDefaults(suiteName: "com.apple.spaces")?.object(forKey: "spans-displays") as? Bool) ?? false)
    }
}
