import AppKit

/// 불러오기 결과 (기획서 12.5 결과 보고)
struct RestoreReport: Codable {
    var moved: [String] = []
    var alreadyInPlace = 0
    var missing: [String] = []      // 저장된 창과 짝이 없음 (앱이 꺼져 있거나 창이 없음)
    var problems: [String] = []     // 옮겼지만 문제가 있거나 옮길 수 없음
    var otherApps: [String] = []    // 다른 앱 처리 결과 (숨김, 종료 요청)
    var spaces: [String] = []       // 가상화면 정리 결과

    var summary: String {
        var parts = ["✅ \(moved.count + alreadyInPlace)개 제자리"]
        if !moved.isEmpty { parts.append("(이동 \(moved.count)개)") }
        if !problems.isEmpty { parts.append("⚠️ \(problems.count)개 문제") }
        if !missing.isEmpty { parts.append("❌ \(missing.count)개 없음") }
        if !otherApps.isEmpty { parts.append("다른 앱 \(otherApps.count)개 처리") }
        return parts.joined(separator: " · ")
    }
}

/// 불러오기 모드 (기획서 12.1)
enum RestoreMode: String {
    case full       // ② 전체 복원: 꺼진 앱 실행, 창 없는 앱에 다시 열기 요청, 브라우저 URL·JetBrains 프로젝트 열기, 뜬 창부터 배치
    case arrange    // ① 배치만: 이미 열린 창만 옮긴다
}

/// 스냅샷대로 창을 모니터·Space·위치·크기로 옮긴다 (기획서 12.1, 2단계 Spaces, 3단계 중 "실행만")
/// Space 이동: ⌃N으로 대상 모니터를 목표 Space로 전환한 뒤 AX로 창을 그 모니터로 옮긴다.
/// 같은 모니터 안에서 Space만 바꿀 때는 다른 모니터를 잠깐 거친다 (0단계 "모니터 경유" 방식)
final class Restorer: @unchecked Sendable {
    private let snapshot: Snapshot
    private let dryRun: Bool
    private let mode: RestoreMode
    private let progress: (String) -> Void
    private var displays: [String: CGRect] = [:]
    private var useUuid: [String: Bool] = [:]
    /// 없는 모니터에 있던 Space 중 macOS가 다른 모니터로 옮겨 둔 것(uuid가 남아 있음). 이 창들은 uuid로 찾는다
    private var followedUuids = Set<String>()
    /// 모니터가 1대일 때 Space 이동의 경유지로 잠깐 만드는 가상 모니터 (필요할 때 한 번 만들고 끝나면 없앤다)
    private var bridge: VirtualDisplay?
    private var bridgeFailed = false
    /// 배치한 창이 들어간 (모니터, Space 번호). 가상화면 정리 때 "필요한 화면"으로 본다
    private var usedSpaces: [String: Set<Int>] = [:]
    /// 가상화면 초기화 후 다시 만들기 (② 전체 복원에서만)
    private var resetSpaces = false
    /// 짝지어진 창 (저장 창 인덱스 → 지금 창). 겹친 순서를 맞출 때 쓴다
    private var matchedLive: [Int: LiveWindow] = [:]

    // MARK: 가상화면 초기화

    /// 자동이면: 스냅샷의 모니터가 없거나, 화면 uuid가 맞지 않으면서 화면 수가 2개 이상 다를 때 초기화
    private func shouldReset() -> Bool {
        switch snapshot.spaceStrategy ?? .auto {
        case .reset: return true
        case .incremental: return false
        case .auto:
            if snapshot.displays.contains(where: { displays[$0.uuid] == nil }) { return true }
            let layout = SpaceService.layout()
            return snapshot.spaces.contains { saved in
                guard let live = layout.first(where: { $0.displayUuid == saved.displayUuid }) else { return false }
                let uuidsMatch = Set(saved.spaces.map(\.uuid)).isSubset(of: Set(live.uuids))
                return !uuidsMatch && abs(live.ids.count - saved.spaces.count) >= 2
            }
        }
    }

    /// 모니터마다 1번만 남기고 가상화면을 지운다. 지운 화면의 창은 1번으로 모인다 (0단계: 보고 있는 화면과 상관없이 1번)
    /// 전체 화면 Space는 건드리지 않는다
    private func clearSpaces() {
        for display in displays.keys {
            guard let screen = DisplayService.current().first(where: { $0.uuid == display })?.frame,
                  let layout = SpaceService.layout().first(where: { $0.displayUuid == display }), layout.ids.count > 1 else { continue }
            _ = SpaceService.switchTo(display: display, index: 1)
            let targets = (2...layout.ids.count).filter { layout.types[$0 - 1] != 4 }
            let removed = SpaceService.removeSpaces(display: display, screen: screen, indexes: targets)
            report.spaces.append("가상화면 초기화: \(removed)개를 지우고 창을 1번에 모음")
            progress("가상화면 초기화: \(layout.ids.count)개 → \(layout.ids.count - removed)개")
        }
    }
    private var report = RestoreReport()

    /// dryRun: 옮기지 않고 저장된 자리와 다른 창만 moved에 담는다 (검증용)
    init(snapshot: Snapshot, mode: RestoreMode = .full, dryRun: Bool = false, progress: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.mode = dryRun ? .arrange : mode
        self.dryRun = dryRun
        self.progress = progress
    }

    func run() -> RestoreReport {
        displays = Dictionary(uniqueKeysWithValues: DisplayService.current().map { ($0.uuid, $0.frame) })
        var windows = snapshot.includedWindows  // 사용자가 뺀 창은 건드리지 않는다
        resetSpaces = !dryRun && mode == .full && shouldReset()
        let extraSpaces = substituteMissingDisplays(&windows)
        if resetSpaces { clearSpaces() }

        if !dryRun && SkyLight.hotKeysAvailable && !SpaceService.disabledDesktopHotKeys().isEmpty {
            SpaceService.enableDesktopHotKeys()
            progress("데스크톱 전환 단축키를 켬")
        }
        if !dryRun { addMissingSpaces(extraSpaces) }
        chooseSpaceLookup(extraSpaces)
        if mode == .full && !dryRun {
            // 다른 앱 처리를 먼저 해서 배치할 때 화면이 덜 복잡하게
            let policy = snapshot.otherAppsPolicy
            let handled = OtherAppsService.apply(policy, for: snapshot)
            if !handled.isEmpty { progress("다른 앱 \(policy.title): \(handled.joined(separator: ", "))") }
            if policy != .keep { report.otherApps = handled.map { "\($0) (\(policy.title))" } }
            let shown = OtherAppsService.unhideIncluded(snapshot)
            if !shown.isEmpty { progress("숨겨져 있던 앱을 다시 보이게 함: \(shown.joined(separator: ", "))") }
        }
        if mode == .full { launchApps() }
        // 모니터가 1대이고 여러 Space에 걸친 배치면 임시 모니터를 처음에 만든다.
        // 만들 때 macOS가 화면보다 큰 창을 줄이는 등 창을 흔들기 때문에, 배치하기 전에 끝나게 한다
        if !dryRun && displays.count == 1 && Set(windows.map(\.spaceIndex)).count > 1 {
            bridge = VirtualDisplay()
            if bridge == nil { bridgeFailed = true } else { progress("모니터가 1대라 임시 모니터를 만듦") }
        }
        placeWindows(windows)
        if !dryRun && mode == .full { tidySpaces(extra: extraSpaces) }
        if let bridge {
            bridge.remove()
            self.bridge = nil
            progress("임시 모니터 제거")
            // macOS가 모니터 구성 변경 뒤 창을 조정하는 것이 조금 늦게 일어나므로 기다렸다가 두 번 맞춘다
            usleep(1_000_000)
            fixFramesAfterBridge(windows)
            usleep(500_000)
            fixFramesAfterBridge(windows)
        }
        if !dryRun { restoreStacking(windows) }
        if !dryRun { returnToSavedSpaces() }
        return report
    }

    // MARK: 없는 모니터 → 비슷한 모니터 (기획서 12.4 #16)

    /// 모니터를 빼면 macOS가 그 Space들을 남은 모니터로 옮긴다 (uuid 유지, 1번 Space는 주 모니터 1번에 합쳐져 사라짐. 0단계).
    /// 1) 없는 모니터의 Space uuid가 다른 모니터에 있으면 그 Space를 그대로 쓴다
    /// 2) uuid를 못 찾은 Space만 비슷한 모니터(같은 크기 +2, 같은 모델명 +1)의 Space 뒤에 새로 붙인다
    /// 창 위치는 모니터 안 비율 좌표로 옮긴다
    private func substituteMissingDisplays(_ windows: inout [SavedWindow]) -> [String: Int] {
        var extra: [String: Int] = [:]
        let live = DisplayService.current()
        let layout = SpaceService.layout()
        func remap(_ i: Int, from missing: SavedDisplay, to target: LiveDisplay) {
            let f = windows[i].frame
            let sx = target.frame.width / missing.frame.width, sy = target.frame.height / missing.frame.height
            let scaled = CGRect(x: target.frame.minX + (f.minX - missing.frame.minX) * sx,
                                y: target.frame.minY + (f.minY - missing.frame.minY) * sy,
                                width: f.width * sx, height: f.height * sy)
            // 비율로 줄이면 메뉴바 영역(y < 메뉴바 아래)에 걸리는 창이 생긴다 → 쓸 수 있는 영역 안으로
            windows[i].frame = DisplayService.clamp(scaled, to: target.uuid)
            windows[i].displayUuid = target.uuid
        }
        for missing in snapshot.displays where displays[missing.uuid] == nil {
            let savedSpaces = snapshot.spaces.first { $0.displayUuid == missing.uuid }?.spaces ?? []
            var notFound: [SavedSpace] = []
            for space in savedSpaces {
                if !resetSpaces, let home = layout.first(where: { $0.uuids.contains(space.uuid) }), let target = live.first(where: { $0.uuid == home.displayUuid }) {
                    followedUuids.insert(space.uuid)
                    for i in windows.indices where windows[i].displayUuid == missing.uuid && windows[i].spaceUuid == space.uuid {
                        remap(i, from: missing, to: target)
                    }
                    progress("\(missing.name)의 가상화면 \(space.index) → \(target.name)에 옮겨져 있는 것을 사용")
                } else {
                    notFound.append(space)
                }
            }
            guard !notFound.isEmpty, let target = live.max(by: { similarity($0, missing) < similarity($1, missing) }) else { continue }
            // 초기화하면 대상 모니터는 스냅샷 화면 수만큼만 남으므로 그 뒤에 붙인다
            let base = (resetSpaces ? savedSpaceCount(target.uuid) : max(savedSpaceCount(target.uuid), layout.first { $0.displayUuid == target.uuid }?.ids.count ?? 0)) + (extra[target.uuid] ?? 0)
            extra[target.uuid, default: 0] += notFound.count
            progress("\(missing.name)의 가상화면 \(notFound.map { String($0.index) }.joined(separator: ", ")) → \(target.name)의 \(base + 1)번부터 새로 만듦")
            for (k, space) in notFound.enumerated() {
                for i in windows.indices where windows[i].displayUuid == missing.uuid && (windows[i].spaceUuid == space.uuid || windows[i].spaceIndex == space.index && windows[i].spaceUuid.isEmpty) {
                    remap(i, from: missing, to: target)
                    windows[i].spaceIndex = base + k + 1
                    windows[i].spaceUuid = ""  // 새로 만드는 Space라 번호로 찾는다
                }
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
        for display in displays.keys {
            guard let frame = DisplayService.current().first(where: { $0.uuid == display })?.frame else { continue }
            let have = layout.first { $0.displayUuid == display }?.ids.count ?? 0
            // 대체로 붙이는 Space는 지금 있는 Space 뒤에 붙인다 (substituteMissingDisplays의 base와 같은 기준). 초기화했으면 스냅샷 수 뒤에
            let need = extra[display] == nil ? savedSpaceCount(display)
                : (resetSpaces ? savedSpaceCount(display) : max(savedSpaceCount(display), have)) + extra[display]!
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
        if resetSpaces { for key in useUuid.keys { useUuid[key] = false } }
    }

    private func targetIndex(_ window: SavedWindow) -> Int {
        let uuids = SpaceService.layout().first { $0.displayUuid == window.displayUuid }?.uuids ?? []
        if useUuid[window.displayUuid] == true || followedUuids.contains(window.spaceUuid),
           !window.spaceUuid.isEmpty, let i = uuids.firstIndex(of: window.spaceUuid) { return i + 1 }
        return min(window.spaceIndex, max(uuids.count, 1))
    }

    // MARK: 앱 실행 (② 전체 복원)

    /// 앱을 띄운 시각. 이때부터 몇 초 동안은 창이 덜 떠서 약한 단서 매칭을 미룬다
    private var launchedAt: [String: Date] = [:]

    /// 포함된 앱 중 꺼진 것을 뒤에서 실행한다 (앞으로 가져오지 않음)
    private func launchApps() {
        let needed = Set(snapshot.includedWindows.map(\.bundleId))
        for app in snapshot.apps where app.isIncluded && (needed.contains(app.bundleId) || snapshot.windowlessAppIndexes.contains { snapshot.apps[$0].bundleId == app.bundleId }) {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).isEmpty,
                  !app.bundleId.isEmpty, FileManager.default.fileExists(atPath: app.path) else {
                if !app.path.isEmpty && !FileManager.default.fileExists(atPath: app.path) { report.missing.append("\(app.name) (설치되어 있지 않음)") }
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration)
            launchedAt[app.bundleId] = Date()
            progress("\(app.name) 실행")
        }
    }

    /// Dock 아이콘을 누른 것과 같은 "다시 열기" 요청. 대부분의 앱이 창이 없으면 새 창을 만든다
    private func reopen(_ path: String) {
        ExternalCommand.openInBackground(app: path)
    }

    // MARK: 창 배치

    /// 창 배치 중에 앱마다 기억하는 것
    private struct Placement {
        var used = Set<CGWindowID>()                    // 이미 짝지은 지금 창
        var blocked: [String: [String]] = [:]           // 입력 대기 앱 → 기다리는 창
        var unresponsive = Set<String>()
        var countSince: [String: (count: Int, since: Date)] = [:]   // 앱의 창 수와 그 수가 된 시각
        var reopened = Set<String>()                    // 다시 열기를 요청한 앱
        var chromeOpened = Set<Int>(), projectOpened = Set<Int>()   // 열어 달라고 한 저장 창
        var placedIndexes = Set<Int>()
        var lastProjectOpen: (index: Int, at: Date)?
        var lastProgress = Date()
    }

    /// 앱마다 따로 보면서 뜬 창부터 배치한다. 한 앱이 늦거나 입력을 기다려도 다른 앱을 막지 않는다 (기획서 12.2 #5, #20)
    private func placeWindows(_ windows: [SavedWindow]) {
        var pending = Array(windows.indices)
        var state = Placement()
        let start = Date()

        while !pending.isEmpty {
            var still: [Int] = []
            for (bundleId, indexes) in Dictionary(grouping: pending, by: { windows[$0].bundleId }) {
                still += placeApp(bundleId, indexes, windows, &state)
            }
            pending = still
            if pending.isEmpty || mode == .arrange { break }
            // 남은 것이 모두 입력 대기·응답 없음 앱이고 15초 진전이 없으면 끝. 아니면 최대 120초
            let elapsed = Date().timeIntervalSince(start)
            let onlyStuck = pending.allSatisfy { state.blocked[windows[$0].bundleId] != nil || state.unresponsive.contains(windows[$0].bundleId) }
            if elapsed > 120 || (elapsed > 20 && onlyStuck && Date().timeIntervalSince(state.lastProgress) > 15) { break }
            sleep(2)
        }
        reportUnplaced(pending, windows, state)
    }

    /// 앱 하나를 훑어 짝지은 창을 옮기고, 아직 짝이 없는 저장 창을 돌려준다.
    /// 그만 기다릴 앱이면 남은 창을 "없음"으로 보고하고 빈 목록을 돌려준다
    private func placeApp(_ bundleId: String, _ indexes: [Int], _ windows: [SavedWindow], _ state: inout Placement) -> [Int] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !apps.isEmpty else { return indexes }
        let appName = windows[indexes[0]].appName
        var scan = AppScan()
        for app in apps {
            let one = WindowService.scan(pid: app.processIdentifier)
            scan.windows += one.windows
            scan.blockers += one.blockers
            scan.maybeBlockers.formUnion(one.maybeBlockers)
            scan.responding = scan.responding && one.responding
        }
        if scan.responding { state.unresponsive.remove(bundleId) } else { state.unresponsive.insert(bundleId) }
        if scan.blockers.isEmpty { state.blocked[bundleId] = nil } else {
            if state.blocked[bundleId] == nil { progress("\(appName): 입력 대기 → 뒤로 미룸") }
            state.blocked[bundleId] = scan.blockers
        }
        let live = scan.windows.filter { !state.used.contains($0.windowID) }
        // 약한 단서(제목 다름 등)는 앱이 안정된 뒤에: 원래 떠 있던 앱이거나, 띄운 지 5초가 지나고 창 수가 4초 동안 그대로일 때
        if state.countSince[bundleId]?.count != live.count { state.countSince[bundleId] = (live.count, Date()) }
        let countStableSince = state.countSince[bundleId]!.since
        let stable = mode == .arrange || launchedAt[bundleId] == nil
            || (Date().timeIntervalSince(launchedAt[bundleId]!) > 5 && Date().timeIntervalSince(countStableSince) > 4)
        let pairs = WindowMatcher.pair(saved: indexes.map { ($0, windows[$0]) }, live: live, allowWeak: stable)
        for pair in pairs {
            matchedLive[pair.savedIndex] = pair.live
            state.placedIndexes.insert(pair.savedIndex)
            state.used.insert(pair.live.windowID)
            place(windows[pair.savedIndex], pair.live)
            state.lastProgress = Date()
        }
        let matched = Set(pairs.map(\.savedIndex))
        let left = indexes.filter { !matched.contains($0) }
        // 크기 고정 작은 창이 저장된 창과 짝이 안 지어졌고 아직 못 찾은 창이 있으면 입력 대기로 본다 (SVN 인증 등)
        var blockers = scan.blockers
        let pairedIDs = Set(pairs.map(\.live.windowID))
        let strayBlockers = live.filter { scan.maybeBlockers.contains($0.windowID) && !pairedIDs.contains($0.windowID) }
        if !left.isEmpty && !strayBlockers.isEmpty {
            blockers += strayBlockers.map { "\($0.title) (\(Int($0.frame.width))x\(Int($0.frame.height)))" }
            if state.blocked[bundleId] == nil { progress("\(appName): 입력 대기 → 뒤로 미룸") }
            state.blocked[bundleId] = blockers
        }
        guard mode == .full, !left.isEmpty else { return left }

        // 앱이 자리 잡았는데(창 수 15초 그대로, 띄운 지 20초 이상) 입력 대기도 아니고 할 수 있는 요청도 다 했으면 그 앱은 그만 기다린다
        let settled = Date().timeIntervalSince(countStableSince) > 15
            && Date().timeIntervalSince(launchedAt[bundleId] ?? .distantPast) > 20
        let isJetBrains = JetBrainsService.isJetBrains(bundleId)
        let triedAll = (state.reopened.contains(bundleId) || !live.isEmpty || bundleId == BrowserService.chrome || isJetBrains)
            && left.allSatisfy { state.chromeOpened.contains($0) || (windows[$0].urls ?? []).isEmpty }
            && left.allSatisfy { state.projectOpened.contains($0) || !WindowMatcher.isProjectTitle(windows[$0]) }
            && Date().timeIntervalSince(state.lastProjectOpen?.at ?? .distantPast) > 15
        if settled, triedAll, blockers.isEmpty, scan.responding {
            report.missing += left.map { "\(windows[$0].appName) \"\(windows[$0].title)\" (앱을 실행했지만 이 창이 열리지 않음)" }
            return []
        }
        requestMissingWindows(bundleId, left, windows, app: apps[0], hasWindows: !live.isEmpty, waitingInput: !blockers.isEmpty,
                              responding: scan.responding, stable: stable, &state)
        return left
    }

    /// ② 아직 뜨지 않은 창을 열어 달라고 요청한다. 다시 열기와 JetBrains 프로젝트는 입력 대기 중이면 미룬다
    private func requestMissingWindows(_ bundleId: String, _ left: [Int], _ windows: [SavedWindow], app: NSRunningApplication,
                                       hasWindows: Bool, waitingInput: Bool, responding: Bool, stable: Bool, _ state: inout Placement) {
        let isJetBrains = JetBrainsService.isJetBrains(bundleId)
        // 창이 하나도 없는 앱(마지막 창을 닫은 앱 등)에 한 번 다시 열기 요청
        if !hasWindows, !waitingInput, stable, !state.reopened.contains(bundleId), bundleId != BrowserService.chrome, !isJetBrains,
           let path = app.bundleURL?.path {
            state.reopened.insert(bundleId)
            progress("\(windows[left[0]].appName): 창이 없어 다시 열기 요청")
            reopen(path)
        }
        // JetBrains: 없는 프로젝트 창을 최근 프로젝트 목록에서 찾아 하나씩 연다. 앞서 연 창이 뜨거나 15초가 지나야 다음 것
        let previousDone = state.lastProjectOpen.map { state.placedIndexes.contains($0.index) || Date().timeIntervalSince($0.at) > 15 } ?? true
        if isJetBrains, !waitingInput, responding, previousDone,
           let i = left.first(where: { WindowMatcher.isProjectTitle(windows[$0]) && !state.projectOpened.contains($0) }) {
            state.projectOpened.insert(i)
            let project = WindowMatcher.titleKey(windows[i].title)
            if let path = JetBrainsService.projectPath(appName: windows[i].appName, project: project), let appPath = app.bundleURL?.path {
                state.lastProjectOpen = (i, Date())
                progress("\(windows[i].appName) 프로젝트 열기: \(project)")
                JetBrainsService.open(project: path, appPath: appPath)
            } else {
                progress("\(windows[i].appName): 최근 프로젝트에서 \(project) 경로를 찾지 못함")
            }
        }
        // Chrome: 세션 복원을 5초 기다린 뒤에도 같은 사이트 창이 없으면 저장한 URL로 한 번 연다
        if bundleId == BrowserService.chrome, Date().timeIntervalSince(launchedAt[bundleId] ?? .distantPast) > 5 {
            for i in left where !state.chromeOpened.contains(i) {
                guard let urls = windows[i].urls, !urls.isEmpty else { continue }
                state.chromeOpened.insert(i)
                progress("Chrome 창 열기: \(urls[0]) 외 \(urls.count - 1)개")
                BrowserService.openChromeWindow(urls)
            }
        }
    }

    /// 끝까지 짝이 없는 창과 문제 앱을 이유별로 보고한다. 입력 대기 앱은 앞으로 띄운다
    private func reportUnplaced(_ pending: [Int], _ windows: [SavedWindow], _ state: Placement) {
        func appName(_ bundleId: String) -> String { windows.first { $0.bundleId == bundleId }?.appName ?? bundleId }
        for (bundleId, blockers) in state.blocked {
            report.problems.append("\(appName(bundleId)): 입력을 기다리는 창 \(blockers.joined(separator: ", "))")
            if !dryRun { NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate() }
        }
        for bundleId in state.unresponsive { report.problems.append("\(appName(bundleId)): 응답 없음") }
        for i in pending {
            let w = windows[i]
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: w.bundleId).isEmpty
            let reason = !running ? "앱이 꺼져 있음" : (state.blocked[w.bundleId] != nil ? "입력 대기 중" : "맞는 창을 찾지 못함 (창이 없거나 다른 창)")
            report.missing.append("\(w.appName) \"\(w.title)\" (\(reason))")
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
        if index != saved.spaceIndex && useUuid[saved.displayUuid] != true && !followedUuids.contains(saved.spaceUuid) {
            report.problems.append("\(name): Space \(saved.spaceIndex)번이 없어 \(index)번에 둠")
        }
        usedSpaces[saved.displayUuid, default: []].insert(index)
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
            var other = displays.first(where: { $0.key != saved.displayUuid })?.value
            // 모니터가 1대뿐이면 거쳐 갈 임시 가상 모니터를 만든다 (마우스 없이, 0단계 "모니터 경유" 방식 그대로)
            if other == nil && now?.display == saved.displayUuid && !bridgeFailed {
                if bridge == nil {
                    bridge = VirtualDisplay()
                    if bridge == nil { bridgeFailed = true } else { progress("모니터가 1대라 임시 모니터를 만듦") }
                }
                other = bridge?.frame
            }
            if now?.display == saved.displayUuid && other == nil {
                // 모니터가 1대뿐이라 거쳐 갈 곳이 없음: 제목 표시줄을 잡고 Space를 바꾼다 (마우스를 잠깐 씀)
                guard SpaceService.moveByDrag(element: element, windowID: live.windowID, display: saved.displayUuid, to: index) else {
                    report.problems.append("\(name): 가상화면 \(index)번으로 옮기지 못함 (모니터 1대, 임시 모니터와 끌어서 옮기기 모두 실패)")
                    return
                }
            } else {
                guard SpaceService.switchTo(display: saved.displayUuid, index: index) else {
                    report.problems.append("\(name): Space 전환 실패 (데스크톱 단축키 확인)")
                    return
                }
                // 같은 모니터 안에서 Space만 바꿀 때: 다른 모니터를 잠깐 거쳐야 현재 Space로 들어온다
                if now?.display == saved.displayUuid, let other {
                    AX.setPosition(element, CGPoint(x: other.minX + 50, y: other.minY + 50))
                    usleep(300_000)
                }
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

    // MARK: 가상화면 정리

    /// 거쳐 갈 모니터(다른 실제 모니터, 없으면 임시 가상 모니터)
    private func bounceFrame(excluding display: String) -> CGRect? {
        if let other = displays.first(where: { $0.key != display })?.value { return other }
        if bridge == nil && !bridgeFailed {
            bridge = VirtualDisplay()
            if bridge == nil { bridgeFailed = true } else { progress("모니터가 1대라 임시 모니터를 만듦") }
        }
        return bridge?.frame
    }

    /// 창을 같은 모니터의 다른 Space로 옮긴다 (위치·크기는 그대로)
    private func move(_ window: LiveWindow, display: String, to index: Int) -> Bool {
        let frame = AX.frame(window.element)
        guard let other = bounceFrame(excluding: display), SpaceService.switchTo(display: display, index: index) else { return false }
        AX.setPosition(window.element, CGPoint(x: other.minX + 50, y: other.minY + 50))
        usleep(300_000)
        AX.setPosition(window.element, frame.origin)
        AX.setSize(window.element, frame.size)
        usleep(200_000)
        return SpaceService.location(of: window.windowID).map { $0.display == display && $0.index == index } == true
    }

    /// 모니터마다 [필요한 화면들][보관 화면 1개] 로 정리한다 (사용자 요구, 2026-10-27).
    /// 필요한 화면 = 스냅샷 화면 수만큼의 앞쪽 + 배치한 창이 들어간 화면. 남는 화면의 창은 보관 화면(남는 화면 중 가장 앞)으로 모으고,
    /// "보관 화면으로 모으기"면 필요한 화면에 있는 다른 앱 창도 보낸다. "남는 가상화면 정리"가 켜져 있으면 빈 남는 화면을 지운다.
    /// 화면 순서는 바꿀 수 없으므로 창을 옮겨서 맞춘다. 전체 화면 Space는 건드리지 않는다
    private func tidySpaces(extra: [String: Int]) {
        let collect = snapshot.otherAppsPolicy == .collect
        let removeEmpty = snapshot.tidySpaces == true
        guard collect || removeEmpty else { return }
        let others = Set(OtherAppsService.others(for: snapshot).compactMap(\.bundleIdentifier))
        let keep = OtherAppsService.alwaysKeep
        var all: [(window: LiveWindow, bundleId: String, name: String)] = []
        for app in WindowService.regularApps() {
            for window in WindowService.scan(pid: app.processIdentifier).windows {
                all.append((window, app.bundleIdentifier ?? "", app.localizedName ?? "?"))
            }
        }
        for display in displays.keys {
            // 임시 모니터가 있으면 macOS가 내장 화면 해상도를 바꾸기도 해서(1800x1169 → 1512x982) 지금 크기를 다시 읽는다
            guard let screen = DisplayService.current().first(where: { $0.uuid == display })?.frame,
                  let layout = SpaceService.layout().first(where: { $0.displayUuid == display }) else { continue }
            let base = max(savedSpaceCount(display) + (extra[display] ?? 0), 1)
            let needed = Set(1...min(base, layout.ids.count)).union(usedSpaces[display] ?? [])
            var spare = layout.ids.indices.map { $0 + 1 }.filter { !needed.contains($0) && layout.types[$0 - 1] != 4 }
            let located = all.compactMap { item -> (window: LiveWindow, bundleId: String, name: String, index: Int)? in
                guard let at = SpaceService.location(of: item.window.windowID), at.display == display else { return nil }
                return (item.window, item.bundleId, item.name, at.index)
            }
            let toCollect = located.filter { item in
                spare.contains(item.index) || (collect && needed.contains(item.index) && others.contains(item.bundleId) && !keep.contains(item.bundleId))
            }
            var storage = spare.min()
            if !toCollect.isEmpty && storage == nil {
                // 남는 화면이 없으면 보관 화면을 하나 만든다
                if SpaceService.addSpaces(display: display, screen: screen, count: 1) == 1 {
                    storage = SpaceService.layout().first { $0.displayUuid == display }?.ids.count
                    report.spaces.append("보관 화면을 새로 만듦 (#\(storage ?? 0))")
                }
            }
            if let storage {
                var moved = 0
                for item in toCollect where item.index != storage {
                    if move(item.window, display: display, to: storage) { moved += 1 } else { report.problems.append("\(item.name) \"\(item.window.title.prefix(30))\": 보관 화면으로 옮기지 못함") }
                }
                if moved > 0 {
                    report.spaces.append("창 \(moved)개를 보관 화면(#\(storage))으로 모음")
                    progress("창 \(moved)개를 보관 화면 #\(storage)으로 모음")
                }
                if !toCollect.isEmpty { spare.removeAll { $0 == storage } }
            }
            guard removeEmpty else { continue }
            // 남는 화면 중 이제 비어 있는 것을 지운다 (보관 화면은 창이 있으면 남김)
            let occupied = Set(all.compactMap { SpaceService.location(of: $0.window.windowID) }.filter { $0.display == display }.map(\.index))
            let removable = spare.filter { !occupied.contains($0) }
            if !removable.isEmpty {
                let removed = SpaceService.removeSpaces(display: display, screen: screen, indexes: removable)
                report.spaces.append("빈 가상화면 \(removed)개 삭제 (\(removable.map { "#\($0)" }.joined(separator: ", ")))")
                progress("빈 가상화면 \(removed)개 삭제")
            }
        }
    }

    /// 임시 모니터를 없애면 macOS가 다시 창 크기를 줄이는 등 흔든다. 같은 Space에 있는 창의 위치·크기만 다시 맞추고
    /// 크기 문제는 이 마지막 결과로 다시 판단한다
    private func fixFramesAfterBridge(_ windows: [SavedWindow]) {
        report.problems.removeAll { $0.contains("(앱이 크기를 제한함)") }
        for (bundleId, indexes) in Dictionary(grouping: windows.indices, by: { windows[$0].bundleId }) {
            var live: [LiveWindow] = []
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) { live += WindowService.scan(pid: app.processIdentifier).windows }
            for pair in WindowMatcher.pair(saved: indexes.map { ($0, windows[$0]) }, live: live, allowWeak: true) {
                let saved = windows[pair.savedIndex], element = pair.live.element
                guard (AX.attribute(element, kAXMinimizedAttribute) as Bool?) != true else { continue }
                var frame = AX.frame(element)
                if abs(frame.minX - saved.frame.minX) >= 2 || abs(frame.minY - saved.frame.minY) >= 2
                    || abs(frame.width - saved.frame.width) >= 2 || abs(frame.height - saved.frame.height) >= 2 {
                    AX.setPosition(element, saved.frame.origin)
                    AX.setSize(element, saved.frame.size)
                    AX.setPosition(element, saved.frame.origin)
                    usleep(100_000)
                    frame = AX.frame(element)
                }
                if abs(frame.width - saved.frame.width) >= 2 || abs(frame.height - saved.frame.height) >= 2 {
                    report.problems.append("\(saved.appName) \"\(saved.title.prefix(30))\": 크기 \(Int(frame.width))x\(Int(frame.height)) (앱이 크기를 제한함)")
                }
            }
        }
    }

    // MARK: 겹친 순서

    /// 가상화면마다 저장된 창끼리 겹치는 곳만, 뒤 창부터 앞 창 순서로 앞으로 올린다.
    /// 다른 앱 창을 올리려면 그 앱을 앞으로 가져와야 해서 화면이 잠깐 바뀐다
    private func restoreStacking(_ windows: [SavedWindow]) {
        let items = matchedLive.compactMap { index, live -> (saved: SavedWindow, live: LiveWindow, order: Int)? in
            guard let order = windows[index].stackOrder, !windows[index].minimized else { return nil }
            return (windows[index], live, order)
        }
        let groups = Dictionary(grouping: items) { "\($0.saved.displayUuid)#\(targetIndex($0.saved))" }
        var adjusted = 0
        for (_, group) in groups where group.count > 1 {
            // 실제로 겹치는 창이 있는 묶음만
            let overlapping = group.contains { a in group.contains { b in a.live.windowID != b.live.windowID && a.saved.frame.intersects(b.saved.frame) } }
            guard overlapping, let display = group.first?.saved.displayUuid else { continue }
            _ = SpaceService.switchTo(display: display, index: targetIndex(group[0].saved))
            for item in group.sorted(by: { $0.order > $1.order }) {   // 뒤 창부터
                AX.setBool(AXUIElementCreateApplication(item.live.pid), kAXFrontmostAttribute, true)
                AXUIElementPerformAction(item.live.element, kAXRaiseAction as CFString)
                usleep(120_000)
            }
            adjusted += 1
        }
        if adjusted > 0 {
            report.spaces.append("겹친 창 순서를 맞춘 가상화면 \(adjusted)개")
            progress("겹친 창 순서 맞춤: 가상화면 \(adjusted)개")
        }
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
