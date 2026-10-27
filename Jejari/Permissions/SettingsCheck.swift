import AppKit
import ApplicationServices

/// 설정 점검 항목 하나 (기획서 13장)
struct CheckItem: Identifiable {
    enum Action { case openSettings, fix, none }
    let id: String
    let title: String
    let detail: String
    let ok: Bool
    let required: Bool      // false면 권장
    let action: Action
}

/// 권한과 macOS 설정이 제자리에 맞는지 점검하고, 바꿀 수 있는 것은 [권장대로]로 맞춘다
enum SettingsCheck {
    static func items() -> [CheckItem] {
        let trusted = AXIsProcessTrusted()
        var items = [CheckItem(
            id: "accessibility", title: "손쉬운 사용 권한",
            detail: trusted ? "허용됨" : "창을 읽고 옮기려면 필요합니다. 시스템 설정에서 제자리를 켜 주세요.",
            ok: trusted, required: true, action: trusted ? .none : .openSettings)]

        let spaces = SkyLight.spacesAvailable
        items.append(CheckItem(
            id: "skylight", title: "가상화면(Spaces) 기능",
            detail: spaces ? "사용 가능" : "이 macOS 버전에서 가상화면 정보를 읽을 수 없습니다. 위치와 크기만 복원합니다.",
            ok: spaces, required: false, action: .none))

        let rearrange = SpaceService.autoRearrangeEnabled
        items.append(CheckItem(
            id: "mru", title: "Spaces 자동 재정렬 끄기",
            detail: rearrange ? "켜져 있으면 가상화면 순서가 저절로 바뀌어 저장한 순서와 어긋납니다." : "꺼짐",
            ok: !rearrange, required: false, action: rearrange ? .fix : .none))

        let disabled = SkyLight.hotKeysAvailable ? SpaceService.disabledDesktopHotKeys() : []
        items.append(CheckItem(
            id: "hotkeys", title: "데스크톱 전환 단축키",
            detail: disabled.isEmpty ? "필요한 단축키가 모두 켜져 있음"
                : "데스크톱 \(disabled.map { String($0 - 117) }.joined(separator: ", "))번 단축키가 꺼져 있습니다. 가상화면 이동에 필요합니다. (⌃1~⌃0, ⌃⌥1~⌃⌥6이 다른 앱 단축키와 겹칠 수 있습니다)",
            ok: disabled.isEmpty, required: false, action: disabled.isEmpty ? .none : .fix))

        let separate = SpaceService.separateSpacesPerDisplay
        items.append(CheckItem(
            id: "separate", title: "디스플레이마다 별도 Spaces",
            detail: separate ? "켜짐" : "꺼져 있으면 모니터별 가상화면을 복원할 수 없습니다. 시스템 설정 → 데스크탑 및 Dock에서 켠 뒤 로그아웃해야 합니다.",
            ok: separate, required: false, action: separate ? .none : .openSettings))
        return items
    }

    static func perform(_ item: CheckItem) {
        switch (item.id, item.action) {
        case ("accessibility", _):
            // 요청 창을 띄워 목록에 제자리를 올리고, 설정 화면도 연다
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case ("mru", .fix):
            SpaceService.setAutoRearrange(false)
        case ("hotkeys", .fix):
            SpaceService.enableDesktopHotKeys()
        case ("separate", _):
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
        default:
            break
        }
    }
}
