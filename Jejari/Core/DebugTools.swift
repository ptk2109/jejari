#if DEBUG
import AppKit

/// 개발 빌드 전용: 복원을 시험하려고 창 몇 개를 일부러 흐트러뜨린다 (jejari://scramble)
enum DebugTools {
    /// 지금 대화 중인 터미널 등은 건드리지 않는다
    static let untouchable: Set<String> = ["com.stablyai.orca"]

    static func drag(appQuery: String, to index: Int) -> [String] {
        var log: [String] = []
        guard let app = WindowService.regularApps().first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(appQuery.lowercased()) }),
              let window = WindowService.scan(pid: app.processIdentifier).windows.first,
              let location = SpaceService.location(of: window.windowID) else { return ["앱/창 없음"] }
        log.append("\(app.localizedName ?? "?") \"\(window.title.prefix(30))\" #\(location.index) → #\(index)")
        let ok = SpaceService.moveByDrag(element: window.element, windowID: window.windowID, display: location.display, to: index) { log.append("   \($0)") }
        log.append(ok ? "성공" : "실패")
        return log
    }

    /// 가상 모니터를 만들어 앱의 첫 창을 그 모니터를 거쳐 다른 Space로 옮긴다 (jejari://debugvd?app=…&to=…)
    static func virtualBounce(appQuery: String, to index: Int) -> [String] {
        var log: [String] = []
        guard let app = WindowService.regularApps().first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(appQuery.lowercased()) }),
              let window = WindowService.scan(pid: app.processIdentifier).windows.first,
              let from = SpaceService.location(of: window.windowID) else { return ["앱/창 없음"] }
        log.append("\(app.localizedName ?? "?") \"\(window.title.prefix(30))\" #\(from.index) → #\(index)")
        let original = AX.frame(window.element)
        let t0 = Date()
        guard let virtual = VirtualDisplay() else { return log + ["가상 모니터를 만들지 못함"] }
        log.append(String(format: "가상 모니터 생성 %.1f초: id %d, %@, 위치 %@", Date().timeIntervalSince(t0), virtual.displayID, virtual.uuid ?? "?", "\(virtual.frame)"))
        log.append("모니터 목록: \(DisplayService.current().map { "\($0.name) \($0.frame)" })")
        log.append("Space: \(SpaceService.layout().map { "\($0.displayUuid.prefix(8)) \($0.ids.count)개" })")
        let switched = SpaceService.switchTo(display: from.display, index: index)
        log.append("목표 #\(index)로 전환: \(switched)")
        AX.setPosition(window.element, CGPoint(x: virtual.frame.minX + 40, y: virtual.frame.minY + 40))
        usleep(400_000)
        log.append("가상 모니터로 보낸 뒤: \(SpaceService.location(of: window.windowID).map { "\($0.display.prefix(8)) #\($0.index)" } ?? "?")")
        AX.setPosition(window.element, original.origin)
        AX.setSize(window.element, original.size)
        usleep(400_000)
        let after = SpaceService.location(of: window.windowID)
        log.append("되돌린 뒤: \(after.map { "\($0.display.prefix(8)) #\($0.index)" } ?? "?"), 위치 \(AX.frame(window.element).origin)")
        let t1 = Date()
        virtual.remove()
        log.append(String(format: "가상 모니터 제거 %.1f초, 남은 모니터 %d대, Space %@", Date().timeIntervalSince(t1), DisplayService.current().count,
                          "\(SpaceService.layout().map { "\($0.displayUuid.prefix(8)) \($0.ids.count)개" })"))
        log.append("최종: \(SpaceService.location(of: window.windowID).map { "#\($0.index)" } ?? "?") \(after?.index == index ? "성공" : "실패")")
        return log
    }

    /// 불러오기 기록마다 snapshot.json과 before.json으로 짝짓기를 다시 돌려, 그때의 짝(report.json의 matches)과 다른 것을 보여 준다.
    /// 짝짓기 규칙을 바꾼 뒤 지난 기록에서 무엇이 달라지는지 확인하는 용도 (jejari://replay).
    /// 불러오기 전에 떠 있던 창(before)끼리만 비교한다. 나중에 뜬 창과의 짝은 다시 만들 수 없어 뺀다.
    /// cluesOnly: 창 번호를 쓰지 않고 단서만으로 짝짓는다. 그때 창 번호로 짝지은 기록이면 그것이 정답이라 단서 짝짓기가 얼마나 틀리는지 잴 수 있다
    static func replay(cluesOnly: Bool = false) -> (summary: String, log: [String]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? { (try? Data(contentsOf: url)).flatMap { try? decoder.decode(T.self, from: $0) } }
        let folders = ((try? FileManager.default.contentsOfDirectory(at: RunLogStore.directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var log: [String] = [], compared = 0, skipped = 0, same = 0, changed = 0
        for folder in folders {
            guard let logged = load(Snapshot.self, folder.appendingPathComponent("snapshot.json")),
                  let before = load(Snapshot.self, folder.appendingPathComponent("before.json")),
                  let recorded = load(RunLogStore.Entry.self, folder.appendingPathComponent("report.json"))?.report.matches else { skipped += 1; continue }
            compared += 1
            // 기록의 배치에는 그때 맞았던 창 번호만 붙어 있다
            let snapshot = cluesOnly ? logged.withoutSession() : logged
            let saved = snapshot.includedWindows
            let beforeIDs = Set(before.windows.compactMap(\.windowID))
            // 나중에 뜬 창과 짝지어졌던 저장 창은 비교에서 뺀다
            let late = Set(recorded.filter { !beforeIDs.contains($0.windowID) }.map(\.saved))
            let then = Dictionary(recorded.filter { beforeIDs.contains($0.windowID) }.map { ($0.saved, $0.windowID) }, uniquingKeysWith: { first, _ in first })
            var now: [Int: CGWindowID] = [:]
            for bundleId in Set(saved.map(\.bundleId)) {
                let indexes = saved.indices.filter { saved[$0].bundleId == bundleId && !late.contains($0) }
                let live = before.windows.filter { $0.bundleId == bundleId && $0.windowID != nil }
                for pair in WindowMatcher.pair(saved: indexes.map { ($0, saved[$0]) }, live: live, id: { $0.windowID ?? 0 }, allowWeak: true) {
                    now[pair.savedIndex] = pair.live.windowID
                }
            }
            var differences: [String] = []
            for i in Set(then.keys).union(now.keys).sorted() {
                if then[i] == now[i] { same += 1; continue }
                changed += 1
                let title = "\(saved[i].appName) \"\(saved[i].title.prefix(30))\""
                func describe(_ id: CGWindowID?) -> String { id.flatMap { id in before.windows.first { $0.windowID == id } }.map { "\"\($0.title.prefix(30))\" (\($0.windowID ?? 0))" } ?? "짝 없음" }
                differences.append("   \(title): 그때 \(describe(then[i])) → 지금 \(describe(now[i]))")
            }
            log.append("\(folder.lastPathComponent): 짝 \(then.count)개 중 다름 \(differences.count)개" + (late.isEmpty ? "" : ", 나중에 뜬 창 \(late.count)개 제외"))
            log += differences
        }
        return ("기록 \(compared)개 비교 (짝 정보가 없는 기록 \(skipped)개 건너뜀): 같음 \(same), 다름 \(changed)", log)
    }

    static func scramble() -> [String] {
        var log: [String] = []
        let displays = DisplayService.current()
        guard let main = displays.first(where: \.isMain) else { return ["주 모니터 없음"] }
        let layout = SpaceService.layout()
        var candidates: [(name: String, window: LiveWindow, display: String, index: Int)] = []
        for app in WindowService.regularApps() where !untouchable.contains(app.bundleIdentifier ?? "") {
            for window in WindowService.scan(pid: app.processIdentifier).windows {
                guard (AX.attribute(window.element, "AXFullScreen") as Bool?) != true,
                      let location = SpaceService.location(of: window.windowID, in: layout) else { continue }
                candidates.append(("\(app.localizedName ?? "?") \"\(window.title.prefix(30))\"", window, location.display, location.index))
            }
        }
        candidates.sort { $0.name < $1.name }
        var used = Set<CGWindowID>()
        func take(_ condition: (String, Int) -> Bool) -> (name: String, window: LiveWindow, display: String, index: Int)? {
            guard let found = candidates.first(where: { !used.contains($0.window.windowID) && condition($0.display, $0.index) }) else { return nil }
            used.insert(found.window.windowID)
            return found
        }

        // 1) 다른 모니터에 있는 창을 주 모니터로
        if let item = take({ display, _ in display != main.uuid }) {
            AX.setPosition(item.window.element, CGPoint(x: main.frame.minX + 60, y: main.frame.minY + 60))
            log.append("\(item.name): \(item.display.prefix(8)) #\(item.index) → 주 모니터")
        }
        // 2) Space가 2개 이상인 모니터에서 다른 Space로 (다른 모니터를 거쳐 돌아옴, 모니터가 1대면 끌어서)
        if let item = take({ display, _ in (layout.first { $0.displayUuid == display }?.ids.count ?? 0) >= 2 }),
           let count = layout.first(where: { $0.displayUuid == item.display })?.ids.count {
            let target = item.index == 1 ? 2 : 1
            let original = item.window.frame
            if let other = displays.first(where: { $0.uuid != item.display }) {
                if SpaceService.switchTo(display: item.display, index: target) {
                    AX.setPosition(item.window.element, CGPoint(x: other.frame.minX + 50, y: other.frame.minY + 50))
                    usleep(300_000)
                    AX.setPosition(item.window.element, original.origin)
                    log.append("\(item.name): #\(item.index) → #\(target) (Space \(count)개 중)")
                }
            } else if let virtual = VirtualDisplay() {
                // 모니터가 1대면 임시 가상 모니터를 거쳐 옮긴다
                if SpaceService.switchTo(display: item.display, index: target) {
                    AX.setPosition(item.window.element, CGPoint(x: virtual.frame.minX + 40, y: virtual.frame.minY + 40))
                    usleep(400_000)
                    AX.setPosition(item.window.element, original.origin)
                    log.append("\(item.name): #\(item.index) → #\(target) (임시 모니터 경유, Space \(count)개 중)")
                }
                virtual.remove()
            } else {
                log.append("\(item.name): 임시 모니터를 만들지 못함")
            }
        }
        // 3) 크기와 위치 바꾸기
        if let item = take({ _, _ in true }) {
            let f = item.window.frame
            AX.setPosition(item.window.element, CGPoint(x: f.minX + 80, y: f.minY + 80))
            AX.setSize(item.window.element, CGSize(width: f.width * 0.7, height: f.height * 0.7))
            log.append("\(item.name): 위치 +80, 크기 70%")
        }
        // 4) 최소화
        if let item = take({ _, _ in true }) {
            AX.setBool(item.window.element, kAXMinimizedAttribute, true)
            log.append("\(item.name): 최소화")
        }
        return log
    }
}

/// 개발 빌드 전용 URL 명령 (jejari://debug…, scramble). 처리했으면 true
extension AppState {
    func handleDebug(_ command: String, _ query: [URLQueryItem]) -> Bool {
        switch command {
        case "debugdrag":
            // jejari://debugdrag?app=<bundle id 일부>&to=<번호>: 그 앱의 첫 창을 끌어서 다른 Space로
            let app = query.first { $0.name == "app" }?.value ?? ""
            let to = Int(query.first { $0.name == "to" }?.value ?? "") ?? 1
            Task.detached {
                let log = DebugTools.drag(appQuery: app, to: to)
                await MainActor.run { self.writeResult(ActionResult(action: "debugdrag", name: app, finishedAt: Date(), ok: true, summary: "끌기 시험", log: log)) }
            }
        case "replay":
            // jejari://replay: 지난 불러오기 기록으로 짝짓기를 다시 돌려 그때와 다른 짝을 보여 준다
            // jejari://replay?clues=1: 창 번호 없이 단서로만 (번호로 짝지은 기록과 비교하면 단서 짝짓기의 정확도)
            let cluesOnly = query.first { $0.name == "clues" }?.value == "1"
            Task.detached {
                let result = DebugTools.replay(cluesOnly: cluesOnly)
                await MainActor.run { self.writeResult(ActionResult(action: "replay", name: "", finishedAt: Date(), ok: result.summary.hasSuffix("다름 0"), summary: result.summary, log: result.log)) }
            }
        case "debugwindows":
            // 제자리 자신의 창 목록 (제목, 크기, 보이는지)
            writeResult(ActionResult(action: "debugwindows", name: "", finishedAt: Date(), ok: true, summary: "",
                                     log: NSApp.windows.map { "\($0.title.isEmpty ? "(제목 없음)" : $0.title) \(Int($0.frame.width))x\(Int($0.frame.height)) 보임=\($0.isVisible) \(type(of: $0))" }))
        case "debugscan":
            // jejari://debugscan?app=…: 그 앱의 모든 AX 창(원격 토큰)과 분류
            let appQuery = (query.first { $0.name == "app" }?.value ?? "").lowercased()
            Task.detached {
                var log: [String] = []
                for app in WindowService.regularApps() where (app.bundleIdentifier ?? "").lowercased().contains(appQuery) {
                    let scan = WindowService.scan(pid: app.processIdentifier)
                    log.append("\(app.localizedName ?? "?"): 창 \(scan.windows.map { "\($0.windowID) \"\($0.title)\" \(Int($0.frame.width))x\(Int($0.frame.height))\(scan.maybeBlockers.contains($0.windowID) ? " (보류)" : "")" }), 입력 대기 \(scan.blockers)")
                    for id: UInt64 in 0..<WindowService.elementScanLimit {
                        guard let el = AX.remoteElement(pid: app.processIdentifier, elementID: id),
                              (AX.attribute(el, kAXRoleAttribute) as String?) == kAXWindowRole, let wid = AX.windowID(el) else { continue }
                        let f = AX.frame(el)
                        log.append("   요소 \(id): wid \(wid) \"\(AX.attribute(el, kAXTitleAttribute) as String? ?? "")\" \(AX.attribute(el, kAXSubroleAttribute) as String? ?? "?") \(Int(f.width))x\(Int(f.height)) Space \(SpaceService.location(of: wid).map { "#\($0.index)" } ?? "없음") 크기변경 \(AX.isSettable(el, kAXSizeAttribute)) 모달 \(AX.attribute(el, kAXModalAttribute) as Bool? ?? false)")
                    }
                }
                await MainActor.run { self.writeResult(ActionResult(action: "debugscan", name: appQuery, finishedAt: Date(), ok: true, summary: "", log: log)) }
            }
        case "debugremove":
            let index = Int(query.first { $0.name == "index" }?.value ?? "") ?? 0
            let view = Int(query.first { $0.name == "view" }?.value ?? "")
            Task.detached {
                var log: [String] = []
                if let main = DisplayService.current().first(where: \.isMain) {
                    if let view { log.append("먼저 #\(view) 보기: \(SpaceService.switchTo(display: main.uuid, index: view))") }
                    let n = SpaceService.removeSpaces(display: main.uuid, screen: main.frame, indexes: [index]) { log.append($0) }
                    log.append("삭제 \(n)개, 지금 \(SpaceService.layout().first { $0.displayUuid == main.uuid }?.ids.count ?? -1)개")
                }
                await MainActor.run { self.writeResult(ActionResult(action: "debugremove", name: "", finishedAt: Date(), ok: true, summary: "", log: log)) }
            }
        case "debugvd":
            let app = query.first { $0.name == "app" }?.value ?? ""
            let to = Int(query.first { $0.name == "to" }?.value ?? "") ?? 1
            Task.detached {
                let log = DebugTools.virtualBounce(appQuery: app, to: to)
                await MainActor.run { self.writeResult(ActionResult(action: "debugvd", name: app, finishedAt: Date(), ok: true, summary: "가상 모니터 시험", log: log)) }
            }
        case "scramble":
            guard AXIsProcessTrusted(), !busy else { return true }
            busy = true
            Task.detached {
                let log = DebugTools.scramble()
                await MainActor.run {
                    self.busy = false
                    self.writeResult(ActionResult(action: "scramble", name: "", finishedAt: Date(), ok: true, summary: "\(log.count)개 흐트러뜨림", log: log))
                }
            }
        default:
            return false
        }
        return true
    }
}
#endif
