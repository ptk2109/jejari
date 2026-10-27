import AppKit
import CoreGraphics

/// 연결된 모니터. 모니터는 displayID가 아니라 UUID로 식별한다 (재연결 때 displayID가 바뀜, 0단계)
struct LiveDisplay {
    let uuid: String
    let name: String
    let frame: CGRect       // CG 전역 좌표
    let isMain: Bool
    let scale: Double
}

enum DisplayService {
    static func uuid(of displayID: CGDirectDisplayID) -> String? {
        CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    }

    static func current() -> [LiveDisplay] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let screens = NSScreen.screens
        return ids.compactMap { id in
            guard let uuid = uuid(of: id) else { return nil }
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            return LiveDisplay(uuid: uuid, name: screen?.localizedName ?? "모니터 \(id)", frame: CGDisplayBounds(id),
                               isMain: CGDisplayIsMain(id) != 0, scale: Double(screen?.backingScaleFactor ?? 1))
        }
    }

    /// 모니터에서 창을 둘 수 있는 영역(메뉴바·Dock 제외)을 CG 좌표(주 모니터 좌상단 원점)로
    static func visibleFrame(of displayUuid: String) -> CGRect? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        for screen in NSScreen.screens {
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  uuid(of: number) == displayUuid else { continue }
            let v = screen.visibleFrame
            return CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
        }
        return nil
    }

    /// 창 영역을 모니터의 쓸 수 있는 영역 안으로 맞춘다. 메뉴바 위로 올라간 창은 macOS가 밀어내므로 미리 맞춘다
    /// (다른 크기 모니터로 대체하거나 해상도가 바뀌어 비율로 옮겼을 때)
    static func clamp(_ frame: CGRect, to displayUuid: String) -> CGRect {
        guard let area = visibleFrame(of: displayUuid) else { return frame }
        let width = min(frame.width, area.width), height = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.minY, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 같은 모델 여러 대는 이름 끝에 " (1)", " (2)"가 붙으므로 떼고 비교한다
    static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }
}
