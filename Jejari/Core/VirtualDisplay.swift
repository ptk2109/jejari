import CoreGraphics
import Foundation

/// 잠깐 쓰는 가상 모니터. 모니터가 1대뿐일 때 "다른 모니터를 거쳐 Space 옮기기"의 경유지로 쓴다.
/// 객체가 살아 있는 동안만 연결되고, 해제하면 사라진다
final class VirtualDisplay: @unchecked Sendable {
    private var display: CGVirtualDisplay?
    let displayID: CGDirectDisplayID

    /// 만들고 macOS가 모니터와 Space를 인식할 때까지 기다린다. 실패하면 nil
    /// 크기는 넉넉하게: 경유하는 창보다 작으면 macOS가 창을 옮기지 않는다 (DataGrip 1512x943 → 1280x800 가상 모니터로 안 옮겨짐)
    init?(width: UInt32 = 3840, height: UInt32 = 2160) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.global(qos: .userInitiated)
        descriptor.name = "제자리 임시 모니터"
        descriptor.maxPixelsWide = width
        descriptor.maxPixelsHigh = height
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.productID = 0x4A4A
        descriptor.vendorID = 0x4A4A
        descriptor.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)]
        guard display.apply(settings) else { return nil }
        self.display = display
        self.displayID = display.displayID
        // 모니터 목록과 Space 목록에 나타날 때까지
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if let uuid, SpaceService.layout().contains(where: { $0.displayUuid == uuid }) { break }
            usleep(100_000)
        }
        usleep(500_000)
    }

    var uuid: String? { DisplayService.uuid(of: displayID) }
    var frame: CGRect { CGDisplayBounds(displayID) }

    /// 없애고 목록에서 사라질 때까지 기다린다
    func remove() {
        let id = uuid
        display = nil
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if !SpaceService.layout().contains(where: { $0.displayUuid == id }) { break }
            usleep(100_000)
        }
        usleep(500_000)
    }

    deinit { display = nil }
}
