import AppKit
import ApplicationServices

/// 지금 열려 있는 창 하나
struct LiveWindow {
    let windowID: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let identifier: String
    let document: String
    let order: Int
    let frame: CGRect
}

/// 앱 하나를 훑은 결과
struct AppScan {
    var windows: [LiveWindow] = []
    var blockers: [String] = []      // 사용자 입력을 기다리는 창 (기획서 12.2 #20)
    /// 크기를 바꿀 수 없는 작은 표준 창. 보통 창(메신저 친구 목록 등)일 수도, 입력 대기(SVN 인증 등)일 수도 있어
    /// windows에 넣어 두고, 저장된 창과 짝이 안 지어진 것만 입력 대기로 본다
    var maybeBlockers: Set<CGWindowID> = []
    var responding = true            // AX 요청에 제한 시간 안에 응답했는지
}

enum WindowService {
    /// 응답 없는 앱 하나가 전체 복원을 붙잡지 않도록 AX 호출마다 거는 제한 시간 (27.2 재부팅 테스트에서 100초 지연)
    static let messagingTimeout: Float = 0.5
    /// 원격 토큰으로 훑는 요소 번호 범위. 실제 창은 대부분 앞쪽 수백 번 안에 있다 (0단계)
    static let elementScanLimit: UInt64 = 3000

    /// 앱의 모든 Space 창. Space가 없는 창(닫힌 대화상자 잔재 등 유령 창)은 뺀다 (0단계: NateOn "열기" 창 33개)
    static func scan(pid: pid_t) -> AppScan {
        var result = AppScan()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var probe: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &probe) == .cannotComplete {
            result.responding = false
            return result
        }
        let layout = SpaceService.layout()
        var seen = Set<CGWindowID>()
        func consider(_ element: AXUIElement) {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard (AX.attribute(element, kAXRoleAttribute) as String?) == kAXWindowRole,
                  let windowID = AX.windowID(element), seen.insert(windowID).inserted,
                  SpaceService.location(of: windowID, in: layout) != nil else { return }
            let frame = AX.frame(element)
            guard frame.width >= 100, frame.height >= 50 else { return }
            let subrole: String = AX.attribute(element, kAXSubroleAttribute) ?? ""
            let title: String = AX.attribute(element, kAXTitleAttribute) ?? ""
            let isDialog = subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
            let small = frame.width < 600 && frame.height < 600
            // 입력 대기 창: 모달 / 작은 대화상자. 크기를 바꿀 수 없는 작은 표준 창은 보류 (maybeBlockers)
            if (AX.attribute(element, kAXModalAttribute) as Bool?) == true || (isDialog && small) {
                result.blockers.append("\(title) (\(Int(frame.width))x\(Int(frame.height)))")
                return
            }
            if subrole == kAXStandardWindowSubrole && small && !AX.isSettable(element, kAXSizeAttribute) {
                result.maybeBlockers.insert(windowID)
            }
            // 모달 창이 떠 있으면 큰 메인 창이 AXDialog로 보이기도 한다 (JetBrains)
            guard subrole == kAXStandardWindowSubrole || isDialog else { return }
            result.windows.append(LiveWindow(
                windowID: windowID, element: element, pid: pid, title: title,
                identifier: AX.attribute(element, kAXIdentifierAttribute) ?? "",
                document: AX.attribute(element, kAXDocumentAttribute) ?? "",
                order: result.windows.count, frame: frame))
        }
        // 다른 가상화면의 창까지 원격 요소 번호로 훑는다
        for elementID in 0..<elementScanLimit {
            if let element = AX.remoteElement(pid: pid, elementID: elementID) { consider(element) }
        }
        // 원격 요소로 창이 안 잡히는 앱이 있어(미리보기) 지금 가상화면의 창은 표준 창 목록으로도 본다
        for element in (AX.attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] { consider(element) }
        return result
    }

    /// 저장할 때 체크를 꺼 둘 앱. 잠깐 열어 두는 창이라 다시 열면 다른 화면으로 열려 짝이 지어지지 않는다
    static let uncheckedByDefault: Set<String> = ["com.apple.systempreferences"]

    /// 일반 앱(Dock에 아이콘이 있는 앱). 자기 자신은 뺀다
    static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    /// 지금 배치를 스냅샷으로 만든다
    static func capture(name: String) -> Snapshot {
        let displays = DisplayService.current()
        let layout = SpaceService.layout()
        var apps: [SavedApp] = []
        var windows: [SavedWindow] = []
        let chromeTabs = BrowserService.chromeWindows()
        // 창 목록은 앞 창부터 뒤 창 순서 (모든 Space 포함)
        let stack = Dictionary((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
            .enumerated().compactMap { item in (item.element[kCGWindowNumber as String] as? CGWindowID).map { ($0, item.offset) } },
            uniquingKeysWith: { first, _ in first })
        for app in regularApps() {
            let bundleId = app.bundleIdentifier ?? ""
            apps.append(SavedApp(bundleId: bundleId, name: app.localizedName ?? bundleId, path: app.bundleURL?.path ?? ""))
            for window in scan(pid: app.processIdentifier).windows {
                guard let location = SpaceService.location(of: window.windowID, in: layout),
                      let display = layout.first(where: { $0.displayUuid == location.display }) else { continue }
                windows.append(SavedWindow(
                    bundleId: bundleId, appName: app.localizedName ?? bundleId, title: window.title,
                    identifier: window.identifier, document: window.document, order: window.order, frame: window.frame,
                    displayUuid: location.display, spaceIndex: location.index, spaceUuid: display.uuids[location.index - 1],
                    minimized: (AX.attribute(window.element, kAXMinimizedAttribute) as Bool?) ?? false,
                    fullScreen: (AX.attribute(window.element, "AXFullScreen") as Bool?) ?? false,
                    urls: bundleId == BrowserService.chrome ? BrowserService.urls(for: window.frame, document: window.document, in: chromeTabs) : nil,
                    stackOrder: stack[window.windowID],
                    excluded: uncheckedByDefault.contains(bundleId) ? true : nil))
            }
        }
        return Snapshot(
            name: name, createdAt: Date(),
            displays: displays.map { SavedDisplay(uuid: $0.uuid, name: $0.name, frame: $0.frame, isMain: $0.isMain, scale: $0.scale) },
            spaces: layout.map { display in
                SavedDisplaySpaces(displayUuid: display.displayUuid, spaces: display.uuids.indices.map {
                    SavedSpace(index: $0 + 1, uuid: display.uuids[$0], type: display.types[$0], isCurrent: display.ids[$0] == display.currentID)
                })
            },
            apps: apps, windows: windows)
    }
}
