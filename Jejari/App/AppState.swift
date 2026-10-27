import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// 외부 명령(jejari://)의 결과. Application Support/Jejari/last-result.json에 남긴다
struct ActionResult: Codable {
    var action: String
    var name: String
    var finishedAt: Date
    var ok: Bool
    var summary: String
    var moved: [String] = []
    var missing: [String] = []
    var problems: [String] = []
    var log: [String] = []
}

/// 앱이 여는 창
enum AppWindow: String {
    case save, edit, manage, result, settings
}

/// 메뉴와 화면이 공유하는 상태. 창 수집과 복원은 시간이 걸리므로 백그라운드에서 돌리고 결과만 메인에서 반영한다
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var snapshots: [Snapshot] = []
    @Published var busy = false
    @Published var status = ""
    @Published var lastReport: RestoreReport?
    @Published var lastReportName = ""
    @Published var checks: [CheckItem] = []

    /// 저장 확인 창에서 고르는 중인 스냅샷 (기획서 12.6)
    @Published var draft: Snapshot?
    @Published var draftName = ""
    /// 배치 관리에서 포함할 창을 다시 고르는 중인 스냅샷
    @Published var editing: Snapshot?

    /// SwiftUI 창을 여는 동작. 메뉴바 아이콘이 나타날 때 받아 둔다
    var openWindowAction: OpenWindowAction?

    var snapshotNames: [String] { snapshots.map(\.name) }
    var canUndo: Bool { SnapshotStore.exists(SnapshotStore.previousStateName) }
    var needsAttention: Bool { checks.contains { !$0.ok && $0.required } }

    static var resultURL: URL { SnapshotStore.directory.deletingLastPathComponent().appendingPathComponent("last-result.json") }

    private init() {
        reload()
    }

    /// 값이 실제로 바뀔 때만 갱신한다. 메뉴바 메뉴는 상태가 바뀔 때마다 다시 그려져서 열린 하위 메뉴가 닫히기 때문
    func reload() {
        let loaded = SnapshotStore.all()
        // 설정 값도 비교에 넣는다 (빠뜨리면 설정을 바꿔도 화면이 예전 값을 보여 줌)
        func signature(_ s: Snapshot) -> String {
            "\(s.name)|\(s.createdAt)|\(s.includedWindows.count)|\(s.otherAppsPolicy)|\(s.tidySpaces ?? false)|\(s.spaceStrategy ?? .auto)"
        }
        if loaded.map(signature) != snapshots.map(signature) {
            snapshots = loaded
        }
        refreshChecks()
    }

    func refreshChecks() {
        let items = SettingsCheck.items()
        if items != checks { checks = items }
    }

    /// 창 제목 (SwiftUI Window 장면과 같게)
    private static let windowTitles: [AppWindow: String] = [
        .save: "배치 저장", .edit: "배치 창 고르기", .manage: "배치 관리", .result: "불러오기 결과", .settings: "제자리 설정",
    ]

    /// 창을 열고 지금 보고 있는 가상화면의 맨 앞으로 가져온다.
    /// Dock 아이콘 없는 메뉴바 앱은 스스로 앞으로 나오기 어렵고, 창이 처음 열린 다른 가상화면에 남아 있을 수 있다
    func open(_ window: AppWindow) {
        openWindowAction?(id: window.rawValue)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let title = Self.windowTitles[window] else { return }
            for nsWindow in NSApp.windows where nsWindow.title == title {
                nsWindow.collectionBehavior.insert(.moveToActiveSpace)
                nsWindow.makeKeyAndOrderFront(nil)
                nsWindow.orderFrontRegardless()
            }
        }
    }

    // MARK: 외부 명령

    /// jejari://save?name=…, restore?name=…[&mode=full|arrange], verify?name=…, undo, status, grant, open?window=… (개발 빌드: scramble)
    /// 외부 명령은 확인 창이나 알림 없이 바로 실행하고 결과를 파일로 남긴다
    func handle(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let name = query.first { $0.name == "name" }?.value ?? "기본"
        let mode = query.first { $0.name == "mode" }?.value.flatMap(RestoreMode.init) ?? .full
        switch url.host {
        case "save": save(name, quiet: true)
        case "restore": restore(name, mode: mode, quiet: true)
        case "verify": restore(name, quiet: true, verifyOnly: true)
        case "undo": restore(SnapshotStore.previousStateName, mode: .arrange, isUndo: true, quiet: true)
        case "collapse": collapse(quiet: true)
        case "wipe": wipe(quiet: true)
        case "grant":
            // 권한 요청 창을 띄워 손쉬운 사용 목록에 제자리를 올리고 설정 화면을 연다
            if let item = SettingsCheck.items().first(where: { $0.id == "accessibility" }) { SettingsCheck.perform(item) }
        case "open":
            // jejari://open?window=save|manage|result|settings
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "window" }?.value ?? ""
            let ready = openWindowAction != nil
            if let window = AppWindow(rawValue: id) { window == .save ? startSave() : open(window) }
            writeResult(ActionResult(action: "open", name: id, finishedAt: Date(), ok: ready && AppWindow(rawValue: id) != nil,
                                     summary: ready ? "\(id) 창 열기" : "창 여는 동작이 아직 준비되지 않음"))
        case "status":
            reload()
            writeResult(ActionResult(action: "status", name: "", finishedAt: Date(), ok: AXIsProcessTrusted(),
                                     summary: checks.map { "\($0.ok ? "✅" : "⚠️") \($0.title): \($0.detail)" }.joined(separator: "\n")))
        #if DEBUG
        case "debugdrag":
            // jejari://debugdrag?app=<bundle id 일부>&to=<번호>: 그 앱의 첫 창을 끌어서 다른 Space로
            let app = query.first { $0.name == "app" }?.value ?? ""
            let to = Int(query.first { $0.name == "to" }?.value ?? "") ?? 1
            Task.detached {
                let log = DebugTools.drag(appQuery: app, to: to)
                await MainActor.run { self.writeResult(ActionResult(action: "debugdrag", name: app, finishedAt: Date(), ok: true, summary: "끌기 시험", log: log)) }
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
            guard AXIsProcessTrusted(), !busy else { return }
            busy = true
            Task.detached {
                let log = DebugTools.scramble()
                await MainActor.run {
                    self.busy = false
                    self.writeResult(ActionResult(action: "scramble", name: "", finishedAt: Date(), ok: true, summary: "\(log.count)개 흐트러뜨림", log: log))
                }
            }
        #endif
        default:
            writeResult(ActionResult(action: url.host ?? "?", name: name, finishedAt: Date(), ok: false, summary: "모르는 명령"))
        }
    }

    private func writeResult(_ result: ActionResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(result).write(to: Self.resultURL, options: .atomic)
    }

    // MARK: 저장

    /// 창을 모은 뒤 저장 확인 창을 연다 (기획서 12.6: 수집된 창을 체크박스로 보여 주고 고르게 한다)
    func startSave() {
        guard ensureAccessibility(quiet: false), !busy else { return }
        busy = true
        status = "창을 모으는 중…"
        draft = nil
        open(.save)
        let suggested = snapshots.first?.name ?? "기본"
        Task.detached {
            let snapshot = WindowService.capture(name: suggested)
            await MainActor.run {
                self.busy = false
                self.status = ""
                self.draft = snapshot
                self.draftName = suggested
            }
        }
    }

    /// 확인 창에서 고른 결과를 저장한다. 뺀 창도 표시만 해서 남긴다
    func commitDraft() {
        guard var snapshot = draft else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != SnapshotStore.previousStateName else { return }
        snapshot.name = name
        snapshot.createdAt = Date()
        do {
            try SnapshotStore.save(snapshot)
            status = "\"\(name)\" 저장: 창 \(snapshot.includedWindows.count)개"
        } catch {
            status = "저장 실패: \(error.localizedDescription)"
        }
        draft = nil
        reload()
    }

    func cancelDraft() { draft = nil }

    /// 외부 명령용: 확인 창 없이 바로 저장
    private func save(_ name: String, quiet: Bool) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        busy = true
        status = "창을 모으는 중…"
        Task.detached {
            let snapshot = WindowService.capture(name: name)
            let result = Result { try SnapshotStore.save(snapshot) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success:
                    self.status = "\"\(name)\" 저장: 창 \(snapshot.windows.count)개, 앱 \(snapshot.apps.count)개"
                case .failure(let error):
                    self.status = "저장 실패: \(error.localizedDescription)"
                }
                self.reload()
                self.writeResult(ActionResult(action: "save", name: name, finishedAt: Date(), ok: (try? result.get()) != nil, summary: self.status,
                                              log: snapshot.windows.map { "\($0.appName) \"\($0.title.prefix(40))\" \($0.displayUuid.prefix(8)) #\($0.spaceIndex)" }))
            }
        }
    }

    // MARK: 관리

    func rename(_ name: String, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != name else { return nil }
        guard trimmed != SnapshotStore.previousStateName else { return "이 이름은 쓸 수 없습니다" }
        do { try SnapshotStore.rename(name, to: trimmed) } catch { return SnapshotStore.exists(trimmed) ? "같은 이름이 이미 있습니다" : error.localizedDescription }
        reload()
        return nil
    }

    /// 포함할 창 다시 고르기
    func startEdit(_ name: String) {
        guard let snapshot = try? SnapshotStore.load(name) else { return }
        editing = snapshot
        open(.edit)
    }

    func commitEdit() {
        guard let snapshot = editing else { return }
        try? SnapshotStore.save(snapshot)
        editing = nil
        reload()
    }

    /// "이름 복사본", 있으면 "이름 복사본 2", 3 … 으로 복제하고 새 이름을 돌려준다
    func duplicate(_ name: String) -> String? {
        guard var snapshot = try? SnapshotStore.load(name) else { return nil }
        var copyName = "\(name) 복사본", number = 2
        while SnapshotStore.exists(copyName) { copyName = "\(name) 복사본 \(number)"; number += 1 }
        snapshot.name = copyName
        snapshot.createdAt = Date()
        guard (try? SnapshotStore.save(snapshot)) != nil else { return nil }
        reload()
        return copyName
    }

    /// 다른 앱 처리 바꾸기
    /// 불러올 때 설정 세 가지를 한 번에 저장
    func saveSettings(_ name: String, policy: OtherAppsPolicy, tidySpaces: Bool, strategy: SpaceStrategy) {
        guard var snapshot = try? SnapshotStore.load(name) else { return }
        snapshot.otherAppsPolicy = policy
        snapshot.tidySpaces = tidySpaces ? true : nil
        snapshot.spaceStrategy = strategy == .auto ? nil : strategy
        try? SnapshotStore.save(snapshot)
        reload()
    }




    func delete(_ name: String) {
        try? SnapshotStore.delete(name)
        reload()
    }

    // MARK: 불러오기

    /// 불러오기 직전 상태를 자동 저장하고 복원한다 (기획서 12.5). 되돌리기와 검증은 직전 상태를 저장하지 않는다
    func restore(_ name: String, mode: RestoreMode = .full, isUndo: Bool = false, quiet: Bool = false, verifyOnly: Bool = false) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let snapshot: Snapshot
        do { snapshot = try SnapshotStore.load(name) } catch {
            status = "불러오기 실패: \(error.localizedDescription)"
            if quiet { writeResult(ActionResult(action: verifyOnly ? "verify" : "restore", name: name, finishedAt: Date(), ok: false, summary: status)) }
            return
        }
        // 종료 요청 배치는 불러오기 전에 목록을 보여 주고 확인한다 (외부 명령은 확인 없이)
        if mode == .full && !verifyOnly && !quiet && snapshot.otherAppsPolicy == .quit {
            let targets = OtherAppsService.quitTargets(for: snapshot).compactMap(\.localizedName)
            if !targets.isEmpty {
                let alert = NSAlert()
                alert.messageText = "다른 앱 \(targets.count)개에 종료를 요청합니다"
                alert.informativeText = targets.joined(separator: ", ") + "\n\n저장하지 않은 문서가 있으면 각 앱이 저장할지 묻습니다."
                alert.addButton(withTitle: "종료하고 불러오기")
                alert.addButton(withTitle: "종료 없이 불러오기")
                alert.addButton(withTitle: "취소")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn: break
                case .alertSecondButtonReturn:
                    var keep = snapshot
                    keep.otherAppsPolicy = .keep
                    return restoreLoaded(keep, name: name, mode: mode, isUndo: isUndo, quiet: quiet, verifyOnly: verifyOnly)
                default: return
                }
            }
        }
        restoreLoaded(snapshot, name: name, mode: mode, isUndo: isUndo, quiet: quiet, verifyOnly: verifyOnly)
    }

    private func restoreLoaded(_ snapshot: Snapshot, name: String, mode: RestoreMode, isUndo: Bool, quiet: Bool, verifyOnly: Bool) {
        busy = true
        status = verifyOnly ? "\"\(name)\" 검증 중…" : "\"\(name)\" 불러오는 중… 키보드와 마우스에서 손을 떼 주세요"
        Task.detached {
            let startedAt = Date()
            // 불러오기 직전 상태: 되돌리기용으로 저장하고, 기록에도 남긴다
            var before: Snapshot?
            if !verifyOnly && (!isUndo || RunLogStore.isEnabled) {
                before = WindowService.capture(name: SnapshotStore.previousStateName)
                if !isUndo, let before { try? SnapshotStore.save(before) }
            }
            let log = LogBox()
            let report = Restorer(snapshot: snapshot, mode: mode, dryRun: verifyOnly) { message in
                log.append(message)
                Task { @MainActor in self.status = message }
            }.run()
            if !verifyOnly && RunLogStore.isEnabled {
                let after = WindowService.capture(name: name)
                RunLogStore.record(.init(snapshot: isUndo ? "되돌리기" : name, mode: mode.rawValue, startedAt: startedAt, finishedAt: Date(),
                                         report: report, log: log.lines), before: before, after: after)
            }
            await MainActor.run {
                self.busy = false
                self.status = verifyOnly ? "검증: 제자리 \(report.alreadyInPlace)개, 다름 \(report.moved.count)개, 없음 \(report.missing.count)개" : report.summary
                if !verifyOnly {
                    self.lastReport = report
                    self.lastReportName = isUndo ? "되돌리기" : name
                }
                self.reload()
                if quiet {
                    self.writeResult(ActionResult(action: verifyOnly ? "verify" : (isUndo ? "undo" : "restore"), name: name, finishedAt: Date(),
                                                  ok: report.problems.isEmpty && report.missing.isEmpty && (!verifyOnly || report.moved.isEmpty),
                                                  summary: self.status, moved: report.moved, missing: report.missing, problems: report.problems, log: log.lines))
                } else if !verifyOnly {
                    self.notify(report)
                }
            }
        }
    }

    // MARK: 🧰 정리하기

    /// 🧲 한 화면으로 모으기: 모니터마다 1번만 남기고 가상화면을 지운다. 되돌리기로 되돌릴 수 있다
    func collapse(quiet: Bool = false) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let count = CleanupService.removableSpaceCount()
        if !quiet {
            guard count > 0 else { return info("지울 가상화면이 없어요", "이미 모니터마다 화면이 하나뿐이에요.") }
            guard confirm("가상화면 \(count)개를 지우고 모든 창을 1번 화면으로 모아요",
                          "앱은 끄지 않아요. 메뉴의 ↩️ 되돌리기로 원래 가상화면과 창 위치로 돌아갈 수 있어요.",
                          ok: "모으기") else { return }
        }
        runCleanup(title: "🧲 한 화면으로 모으기", quitApps: [], quiet: quiet)
    }

    /// 🧹 깨끗하게 비우기: 가상화면을 모두 지우고 앱에 종료를 요청한다 (제자리, Finder, 항상 건드리지 않을 앱은 빼고)
    func wipe(quiet: Bool = false) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let targets = CleanupService.quitTargets()
        if !quiet {
            let names = targets.compactMap(\.localizedName)
            guard confirm("가상화면 \(CleanupService.removableSpaceCount())개를 지우고 앱 \(names.count)개에 종료를 요청해요",
                          names.joined(separator: ", ") + "\n\n저장 안 한 문서가 있으면 각 앱이 저장할지 물어요. Finder와 '항상 건드리지 않을 앱'은 끄지 않아요.\n↩️ 되돌리기는 가상화면과 창 위치만 되돌리고, 끈 앱을 다시 켜지는 않아요.",
                          ok: "비우기") else { return }
        }
        runCleanup(title: "🧹 깨끗하게 비우기", quitApps: targets, quiet: quiet)
    }

    private func runCleanup(title: String, quitApps: [NSRunningApplication], quiet: Bool) {
        busy = true
        status = "\(title) 중… 키보드와 마우스에서 손을 떼 주세요"
        Task.detached {
            // 되돌리기용 직전 상태
            try? SnapshotStore.save(WindowService.capture(name: SnapshotStore.previousStateName))
            let log = LogBox()
            var report = RestoreReport()
            report.spaces = CleanupService.collapseSpaces { message in
                log.append(message)
                Task { @MainActor in self.status = message }
            }
            report.otherApps = CleanupService.quit(quitApps).map { "\($0) (종료 요청)" }
            await MainActor.run {
                self.busy = false
                self.lastReport = report
                self.lastReportName = title
                self.status = "\(title) 끝: 가상화면 정리 \(report.spaces.count)곳\(quitApps.isEmpty ? "" : ", 앱 \(report.otherApps.count)개 종료 요청")"
                self.reload()
                if quiet {
                    self.writeResult(ActionResult(action: quitApps.isEmpty ? "collapse" : "wipe", name: "", finishedAt: Date(), ok: true,
                                                  summary: self.status, problems: report.problems, log: report.spaces + report.otherApps))
                } else {
                    self.notify(report)
                }
            }
        }
    }

    private func confirm(_ title: String, _ message: String, ok: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 되돌리기는 ① 배치만으로 (기획서 12.5)
    func undo() { restore(SnapshotStore.previousStateName, mode: .arrange, isUndo: true) }

    // MARK: 결과 보고 (기획서 12.5)

    /// 알림 배너로 요약을 보여 준다. 알림이 허용되지 않았으면 결과 창을 연다. 알림을 누르면 결과 창이 열린다 (AppDelegate)
    private func notify(_ report: RestoreReport) {
        let center = UNUserNotificationCenter.current()
        let title = lastReportName
        let body = ([report.summary] + report.problems.prefix(2) + report.missing.prefix(2).map { "없음: \($0)" }).joined(separator: "\n")
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in AppState.shared.open(.result) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "제자리: \(title)"
            content.body = body
            center.add(UNNotificationRequest(identifier: "restore-result", content: content, trigger: nil))
        }
    }

    // MARK: 권한

    /// 손쉬운 사용 권한이 없으면 안내하고 false (기획서 12.4 #19). quiet면 안내 대신 결과 파일에 남긴다
    private func ensureAccessibility(quiet: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        if quiet {
            writeResult(ActionResult(action: "permission", name: "", finishedAt: Date(), ok: false, summary: "손쉬운 사용 권한 없음"))
            return false
        }
        let alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한이 필요합니다"
        alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 제자리를 켠 뒤 다시 시도해 주세요."
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, let item = checks.first(where: { $0.id == "accessibility" }) {
            SettingsCheck.perform(item)
        }
        return false
    }
}

/// 백그라운드 복원 중 진행 메시지를 모은다
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
