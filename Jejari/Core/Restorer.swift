import AppKit

/// 불러오기 결과 (기획서 12.5 결과 보고)
struct RestoreReport {
    var moved: [String] = []
    var alreadyInPlace = 0
    var missing: [String] = []      // 저장된 창과 짝이 없음 (앱이 꺼져 있거나 창이 없음)
    var problems: [String] = []     // 옮겼지만 문제가 있거나 옮길 수 없음

    var summary: String {
        var parts = ["✅ \(moved.count + alreadyInPlace)개 제자리"]
        if !moved.isEmpty { parts.append("(이동 \(moved.count)개)") }
        if !problems.isEmpty { parts.append("⚠️ \(problems.count)개 문제") }
        if !missing.isEmpty { parts.append("❌ \(missing.count)개 없음") }
        return parts.joined(separator: " · ")
    }
}

/// 스냅샷대로 이미 열린 창을 모니터·Space·위치·크기로 옮긴다 (기획서 12.1 ① 배치만 + 2단계 Spaces)
/// Space 이동: ⌃N으로 대상 모니터를 목표 Space로 전환한 뒤 AX로 창을 그 모니터로 옮긴다.
/// 같은 모니터 안에서 Space만 바꿀 때는 다른 모니터를 잠깐 거친다 (0단계 "모니터 경유" 방식)
final class Restorer: @unchecked Sendable {
    private let snapshot: Snapshot
    private let dryRun: Bool
    private let progress: (String) -> Void
    private var displays: [String: CGRect] = [:]
    private var useUuid: [String: Bool] = [:]
    private var report = RestoreReport()

    /// dryRun: 옮기지 않고 저장된 자리와 다른 창만 moved에 담는다 (검증용)
    init(snapshot: Snapshot, dryRun: Bool = false, progress: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.dryRun = dryRun
        self.progress = progress
    }

    func run() -> RestoreReport {
        displays = Dictionary(uniqueKeysWithValues: DisplayService.current().map { ($0.uuid, $0.frame) })
        var windows = snapshot.windows
        let extraSpaces = substituteMissingDisplays(&windows)

        if !dryRun && SkyLight.hotKeysAvailable && !SpaceService.disabledDesktopHotKeys().isEmpty {
            SpaceService.enableDesktopHotKeys()
            progress("데스크톱 전환 단축키를 켬")
        }
        if !dryRun { addMissingSpaces(extraSpaces) }
        chooseSpaceLookup(extraSpaces)
        placeWindows(windows)
        if !dryRun { returnToSavedSpaces() }
        return report
    }

    // MARK: 없는 모니터 → 비슷한 모니터 (기획서 12.4 #16)

    /// 없는 모니터마다 같은 크기(+2)·같은 모델명(+1)이 가장 높은 모니터를 고른다.
    /// 없는 모니터의 Space i → 대체 모니터의 (원래 Space 수 + 앞서 붙인 수 + i)번, 창 위치는 모니터 안 비율 좌표로
    private func substituteMissingDisplays(_ windows: inout [SavedWindow]) -> [String: Int] {
        var extra: [String: Int] = [:]
        let live = DisplayService.current()
        for missing in snapshot.displays where displays[missing.uuid] == nil {
            guard let target = live.max(by: { similarity($0, missing) < similarity($1, missing) }) else { continue }
            let base = savedSpaceCount(target.uuid) + (extra[target.uuid] ?? 0)
            extra[target.uuid, default: 0] += savedSpaceCount(missing.uuid)
            progress("\(missing.name) 없음 → \(target.name)의 Space \(base + 1)번부터 대체")
            let sx = target.frame.width / missing.frame.width, sy = target.frame.height / missing.frame.height
            for i in windows.indices where windows[i].displayUuid == missing.uuid {
                let f = windows[i].frame
                windows[i].frame = CGRect(x: target.frame.minX + (f.minX - missing.frame.minX) * sx,
                                          y: target.frame.minY + (f.minY - missing.frame.minY) * sy,
                                          width: f.width * sx, height: f.height * sy)
                windows[i].displayUuid = target.uuid
                windows[i].spaceIndex += base
                windows[i].spaceUuid = ""  // 새로 만드는 Space라 번호로 찾는다
            }
        }
        return extra
    }

    private func similarity(_ display: LiveDisplay, _ saved: SavedDisplay) -> Int {
        (abs(display.frame.width - saved.frame.width) < 1 && abs(display.frame.height - saved.frame.height) < 1 ? 2 : 0)
            + (DisplayService.baseName(display.name) == DisplayService.baseName(saved.name) ? 1 : 0)
    }

    private func savedSpaceCount(_ display: String) -> Int {
        snapshot.spaces.first { $0.displayUuid == display }?.spaces.count ?? 0
    }

    // MARK: Space 준비

    /// 모니터의 Space가 스냅샷(+대체분)보다 적으면 Mission Control로 추가 (기획서 12.4 #18)
    private func addMissingSpaces(_ extra: [String: Int]) {
        let layout = SpaceService.layout()
        for (display, frame) in displays {
            let need = savedSpaceCount(display) + (extra[display] ?? 0)
            let have = layout.first { $0.displayUuid == display }?.ids.count ?? 0
            guard need > have else { continue }
            let added = SpaceService.addSpaces(display: display, screen: frame, count: need - have)
            progress("Space \(have)개 → \(need)개 필요, \(added)개 추가")
            if added < need - have { report.problems.append("Space \(need - have - added)개를 만들지 못함. 직접 추가해 주세요") }
        }
    }

    /// 저장한 Space uuid가 그 모니터에 모두 남아 있으면 uuid로, 하나라도 빠졌으면 그 모니터 전체를 번호로 찾는다.
    /// 창마다 섞어 쓰면 같은 Space에 있던 창들이 갈라지거나 다른 묶음과 합쳐진다 (0단계)
    private func chooseSpaceLookup(_ extra: [String: Int]) {
        let layout = SpaceService.layout()
        for saved in snapshot.spaces {
            let liveUuids = Set(layout.first { $0.displayUuid == saved.displayUuid }?.uuids ?? [])
            useUuid[saved.displayUuid] = !saved.spaces.isEmpty && Set(saved.spaces.map(\.uuid)).isSubset(of: liveUuids)
        }
        for display in extra.keys { useUuid[display] = useUuid[display] ?? false }
    }

    private func targetIndex(_ window: SavedWindow) -> Int {
        let uuids = SpaceService.layout().first { $0.displayUuid == window.displayUuid }?.uuids ?? []
        if useUuid[window.displayUuid] == true, !window.spaceUuid.isEmpty, let i = uuids.firstIndex(of: window.spaceUuid) { return i + 1 }
        return min(window.spaceIndex, max(uuids.count, 1))
    }

    // MARK: 창 배치

    private func placeWindows(_ windows: [SavedWindow]) {
        let groups = Dictionary(grouping: windows.indices, by: { windows[$0].bundleId })
        for (bundleId, indexes) in groups {
            let name = windows[indexes[0]].appName
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            guard !apps.isEmpty else {
                report.missing += indexes.map { "\(name) \"\(windows[$0].title)\" (앱이 꺼져 있음)" }
                continue
            }
            var live: [LiveWindow] = []
            for app in apps {
                let scan = WindowService.scan(pid: app.processIdentifier)
                if !scan.responding { report.problems.append("\(name): 응답 없음") }
                if !scan.blockers.isEmpty { report.problems.append("\(name): 입력을 기다리는 창 \(scan.blockers.joined(separator: ", "))") }
                live += scan.windows
            }
            // ① 배치만 모드는 앱이 이미 떠 있으므로 약한 단서도 바로 배정한다
            let pairs = WindowMatcher.pair(saved: indexes.map { ($0, windows[$0]) }, live: live, allowWeak: true)
            let matched = Set(pairs.map(\.savedIndex))
            report.missing += indexes.filter { !matched.contains($0) }.map { "\(name) \"\(windows[$0].title)\"" }
            for pair in pairs { place(windows[pair.savedIndex], pair.live) }
        }
    }

    private func place(_ saved: SavedWindow, _ live: LiveWindow) {
        let name = "\(saved.appName) \"\(saved.title.prefix(30))\""
        guard displays[saved.displayUuid] != nil else { report.problems.append("\(name): 모니터 없음"); return }
        let element = live.element
        if (AX.attribute(element, "AXFullScreen") as Bool?) == true {
            report.problems.append("\(name): 전체 화면이라 옮길 수 없음")
            return
        }
        let index = targetIndex(saved)
        if index != saved.spaceIndex && useUuid[saved.displayUuid] != true {
            report.problems.append("\(name): Space \(saved.spaceIndex)번이 없어 \(index)번에 둠")
        }
        let now = SpaceService.location(of: live.windowID)
        let current = AX.frame(element)
        let samePlace = now?.display == saved.displayUuid && now?.index == index
        let sameFrame = abs(current.minX - saved.frame.minX) < 2 && abs(current.minY - saved.frame.minY) < 2
            && abs(current.width - saved.frame.width) < 2 && abs(current.height - saved.frame.height) < 2
        // 최소화 상태도 저장과 같아야 제자리 (위치·크기는 최소화돼도 그대로라 따로 비교)
        let minimizedNow = (AX.attribute(element, kAXMinimizedAttribute) as Bool?) ?? false
        if samePlace && sameFrame && minimizedNow == saved.minimized { report.alreadyInPlace += 1; return }
        if dryRun {
            let what = samePlace ? (sameFrame ? "최소화 상태만" : "위치/크기만") : ""
            report.moved.append("\(name): \(now.map { "\($0.display.prefix(8)) #\($0.index)" } ?? "?") → \(saved.displayUuid.prefix(8)) #\(index)\(what.isEmpty ? "" : " (\(what))")")
            return
        }

        if minimizedNow {
            AX.setBool(element, kAXMinimizedAttribute, false)
            usleep(500_000)
        }
        if !samePlace {
            guard SpaceService.switchTo(display: saved.displayUuid, index: index) else {
                report.problems.append("\(name): Space 전환 실패 (데스크톱 단축키 확인)")
                return
            }
            // 같은 모니터 안에서 Space만 바꿀 때: 다른 모니터를 잠깐 거쳐야 현재 Space로 들어온다
            if now?.display == saved.displayUuid, let other = displays.first(where: { $0.key != saved.displayUuid })?.value {
                AX.setPosition(element, CGPoint(x: other.minX + 50, y: other.minY + 50))
                usleep(300_000)
            }
        }
        AX.setPosition(element, saved.frame.origin)
        AX.setSize(element, saved.frame.size)
        AX.setPosition(element, saved.frame.origin)
        usleep(200_000)
        if saved.minimized { AX.setBool(element, kAXMinimizedAttribute, true) }

        let after = SpaceService.location(of: live.windowID), result = AX.frame(element)
        guard after?.display == saved.displayUuid, after?.index == index,
              abs(result.minX - saved.frame.minX) < 2, abs(result.minY - saved.frame.minY) < 2 else {
            report.problems.append("\(name): 옮긴 뒤 위치 확인 실패")
            return
        }
        if abs(result.width - saved.frame.width) >= 2 || abs(result.height - saved.frame.height) >= 2 {
            report.problems.append("\(name): 크기 \(Int(result.width))x\(Int(result.height)) (앱이 크기를 제한함)")
        }
        report.moved.append(name)
        progress("\(name) 이동")
    }

    /// 모니터마다 저장 당시 보던 Space로 돌아간다 (uuid 우선, 없으면 번호)
    private func returnToSavedSpaces() {
        for saved in snapshot.spaces where displays[saved.displayUuid] != nil {
            guard let current = saved.spaces.first(where: \.isCurrent) else { continue }
            let uuids = SpaceService.layout().first { $0.displayUuid == saved.displayUuid }?.uuids ?? []
            let index = uuids.firstIndex(of: current.uuid).map { $0 + 1 } ?? min(current.index, max(uuids.count, 1))
            SpaceService.switchTo(display: saved.displayUuid, index: index)
        }
    }
}
