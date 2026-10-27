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

    /// 같은 모델 여러 대는 이름 끝에 " (1)", " (2)"가 붙으므로 떼고 비교한다
    static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }
}
