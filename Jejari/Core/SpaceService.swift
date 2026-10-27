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

    /// 데스크톱 N 단축키를 사용자가 설정한 키 조합 그대로 보내서 Space를 전환하고, 바뀔 때까지 기다린다
    @discardableResult
    static func switchTo(display: String, index: Int) -> Bool {
        if currentIndex(of: display) == index { return true }
        guard let number = globalNumber(display: display, index: index) else { return false }
        let id = Int32(117 + number)
        guard desktopHotKeyRange.contains(id), SkyLight.hotKeyEnabled(id), let key = SkyLight.hotKeyValue(id) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: UInt64(key.modifiers))
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        let start = Date()
        while currentIndex(of: display) != index && Date().timeIntervalSince(start) < 2 { usleep(50_000) }
        usleep(250_000)  // 전환 애니메이션 마무리
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
    private static func withMissionControl(screen: CGRect, _ body: (AXUIElement) -> Void) -> Bool {
        guard let windowManager else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        defer { if missionControlOpen() { pressEscape(); usleep(800_000) } }
        var region: AXUIElement?
        let start = Date()
        while region == nil && Date().timeIntervalSince(start) < 3 {
            usleep(200_000)
            region = AX.find(windowManager, identifier: "mc.display").first { AX.frame($0) == screen }
        }
        guard let region else { return false }
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
    static func removeSpaces(display: String, screen: CGRect, indexes: [Int]) -> Int {
        var removed = 0
        _ = withMissionControl(screen: screen) { region in
            for index in indexes.sorted(by: >) {
                guard let list = AX.find(region, identifier: "mc.spaces.list").first else { break }
                let thumbnails: [AXUIElement] = AX.attribute(list, kAXChildrenAttribute) ?? []
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
