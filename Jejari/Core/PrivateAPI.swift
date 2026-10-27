import ApplicationServices
import CoreGraphics
import Foundation

// 비공개 API. macOS 업데이트로 사라지거나 바뀔 수 있으므로 SkyLight는 dlsym으로 찾고, 없으면 해당 기능을 끈다.
// 0단계 검증: macOS 27.0.1, 27.2에서 동작 확인

/// AX 창 요소 → CGWindowID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// pid + 요소 번호로 AX 요소를 만든다. 표준 kAXWindows는 현재 Space의 창만 주므로, 다른 Space의 창을 찾을 때 쓴다 (yabai 방식)
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias IsHotKeyEnabled = @convention(c) (Int32) -> Bool
    private typealias SetHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias GetHotKeyValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let isHotKeyEnabled = symbol("SLSIsSymbolicHotKeyEnabled", as: IsHotKeyEnabled.self)
    private static let setHotKeyEnabled = symbol("SLSSetSymbolicHotKeyEnabled", as: SetHotKeyEnabled.self)
    private static let getHotKeyValue = symbol("SLSGetSymbolicHotKeyValue", as: GetHotKeyValue.self)

    /// Space 조회에 필요한 함수가 모두 있는지
    static var spacesAvailable: Bool { mainConnection != nil && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil }
    /// 단축키 조회/변경 함수가 모두 있는지
    static var hotKeysAvailable: Bool { isHotKeyEnabled != nil && setHotKeyEnabled != nil && getHotKeyValue != nil }

    private static var connection: Int32 { mainConnection?() ?? 0 }

    /// 모니터별 Space 목록. 원본 딕셔너리 그대로 (Display Identifier, Spaces, Current Space)
    static func managedDisplaySpaces() -> [[String: Any]] {
        copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// 창이 속한 Space id들. mask 0x7 = 모든 Space
    static func spaces(for windowID: CGWindowID) -> [UInt64] {
        copySpacesForWindows?(connection, 0x7, [windowID] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
    }

    static func hotKeyEnabled(_ id: Int32) -> Bool { isHotKeyEnabled?(id) ?? false }

    @discardableResult
    static func setHotKey(_ id: Int32, enabled: Bool) -> Bool { setHotKeyEnabled?(id, enabled) == 0 }

    /// 사용자가 설정한 키 조합 (키코드, 수정키)
    static func hotKeyValue(_ id: Int32) -> (keyCode: UInt16, modifiers: UInt32)? {
        guard let getHotKeyValue else { return nil }
        var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt32 = 0
        guard getHotKeyValue(id, &character, &keyCode, &modifiers) == 0 else { return nil }
        return (keyCode, modifiers)
    }
}

/// AX 공통 함수
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? T : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value: AXValue = attribute(element, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &origin) }
        if let value: AXValue = attribute(element, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    static func setBool(_ element: AXUIElement, _ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    /// 원격 토큰으로 pid의 AX 요소 하나를 만든다. 토큰 20바이트: pid(4) + 0(4) + 'coco'(4) + 요소 번호(8)
    static func remoteElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            bytes.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            bytes.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self)
            bytes.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
        }
        return _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue()
    }

    /// 하위 요소에서 identifier가 같은 것을 찾는다
    static func find(_ element: AXUIElement, identifier: String, depth: Int = 0) -> [AXUIElement] {
        var found: [AXUIElement] = []
        if (attribute(element, kAXIdentifierAttribute) as String?) == identifier { found.append(element) }
        if depth < 12 {
            for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                found += find(child, identifier: identifier, depth: depth + 1)
            }
        }
        return found
    }
}
