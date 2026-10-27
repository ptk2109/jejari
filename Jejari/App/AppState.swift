import AppKit
import SwiftUI
@preconcurrency import UserNotifications

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
    /// 저장 창에서 덮어쓸 기존 배치. nil이면 새 배치 (이름은 draftName)
    @Published private(set) var draftTarget: String?
    /// 방금 찍은 그대로. 대상을 바꿀 때마다 여기서 다시 이어받는다
    private var capturedDraft: Snapshot?
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

    // MARK: 저장

    /// 창을 모은 뒤 저장 확인 창을 연다 (기획서 12.6: 수집된 창을 체크박스로 보여 주고 고르게 한다)
    func startSave() {
        guard ensureAccessibility(quiet: false), !busy else { return }
        busy = true
        status = "창을 모으는 중…"
        draft = nil
        open(.save)
        // 처음 고를 대상: 마지막으로 불러온 배치, 없으면 가장 최근 저장한 배치. 하나도 없으면 새 배치
        let names = snapshotNames
        let target = names.contains(Self.lastRestoredName) ? Self.lastRestoredName : names.first
        Task.detached {
            let snapshot = WindowService.capture(name: target ?? "")
            await MainActor.run {
                self.busy = false
                self.status = ""
                self.capturedDraft = snapshot
                self.selectDraftTarget(target)
            }
        }
    }

    /// 저장 창의 대상 바꾸기. 기존 배치면 그 설정과 뺀 앱·창을 이어받고, 새 배치면 찍은 그대로
    func selectDraftTarget(_ name: String?) {
        guard let captured = capturedDraft else { return }
        draftTarget = name
        if let name, let old = try? SnapshotStore.load(name) {
            draft = captured.inheriting(from: old)
            draftName = name
        } else {
            draft = captured
            draftName = ""
        }
    }

    /// 저장 창에서 지금 이름으로 저장할 수 있는지. 새 배치는 기존 이름과 겹치면 안 된다 (덮어쓰기는 목록에서 고른다)
    var draftNameProblem: String? {
        if draftTarget != nil { return nil }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "" }
        if name == SnapshotStore.previousStateName { return "이 이름은 쓸 수 없어요." }
        if snapshotNames.contains(name) { return "이미 있는 이름이에요. 덮어쓰려면 목록에서 고르세요." }
        return nil
    }

    /// 마지막으로 불러온 배치 (되돌리기·검증 제외). 저장 창의 처음 대상
    private static var lastRestoredName: String {
        get { UserDefaults.standard.string(forKey: "lastRestoredSnapshot") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastRestoredSnapshot") }
    }

    /// 확인 창에서 고른 결과를 저장한다. 뺀 창도 표시만 해서 남긴다
    func commitDraft() {
        guard var snapshot = draft, draftNameProblem == nil else { return }
        let name = draftTarget ?? draftName.trimmingCharacters(in: .whitespaces)
        snapshot.name = name
        snapshot.createdAt = Date()
        do {
            try SnapshotStore.save(snapshot)
            status = "\"\(name)\" 저장: 창 \(snapshot.includedWindows.count)개"
        } catch {
            status = "저장 실패: \(error.localizedDescription)"
        }
        cancelDraft()
        reload()
    }

    func cancelDraft() {
        draft = nil
        capturedDraft = nil
        draftTarget = nil
    }

    /// 외부 명령용: 확인 창 없이 바로 저장. 같은 이름이 있으면 저장 창처럼 설정과 뺀 앱·창을 이어받는다
    func save(_ name: String, quiet: Bool) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        busy = true
        status = "창을 모으는 중…"
        let old = try? SnapshotStore.load(name)
        Task.detached {
            var snapshot = WindowService.capture(name: name)
            if let old { snapshot = snapshot.inheriting(from: old) }
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
        if Self.lastRestoredName == name { Self.lastRestoredName = trimmed }
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
    /// ask: 종료 요청 배치면 끌 앱 목록을 보여 주고 확인한다 (외부 명령은 배포판에서만)
    func restore(_ name: String, mode: RestoreMode = .full, isUndo: Bool = false, quiet: Bool = false, ask: Bool = true, verifyOnly: Bool = false) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let snapshot: Snapshot
        do { snapshot = try SnapshotStore.load(name) } catch {
            status = "불러오기 실패: \(error.localizedDescription)"
            if quiet { writeResult(ActionResult(action: verifyOnly ? "verify" : "restore", name: name, finishedAt: Date(), ok: false, summary: status)) }
            return
        }
        // 종료 요청 배치는 불러오기 전에 목록을 보여 주고 확인한다
        if mode == .full && !verifyOnly && !isUndo && ask && snapshot.otherAppsPolicy == .quit {
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
                default: return cancelled("restore", name: name, quiet: quiet)
                }
            }
        }
        restoreLoaded(snapshot, name: name, mode: mode, isUndo: isUndo, quiet: quiet, verifyOnly: verifyOnly)
    }

    private func restoreLoaded(_ snapshot: Snapshot, name: String, mode: RestoreMode, isUndo: Bool, quiet: Bool, verifyOnly: Bool) {
        busy = true
        if !isUndo && !verifyOnly { Self.lastRestoredName = name }
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
    func collapse(quiet: Bool = false, ask: Bool = true) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let count = CleanupService.removableSpaceCount()
        if count == 0 && !quiet { return info("지울 가상화면이 없어요", "이미 모니터마다 화면이 하나뿐이에요.") }
        if ask && count > 0 {
            guard confirm("가상화면 \(count)개를 지우고 모든 창을 1번 화면으로 모아요",
                          "앱은 끄지 않아요. 메뉴의 ↩️ 되돌리기로 원래 가상화면과 창 위치로 돌아갈 수 있어요.",
                          ok: "모으기") else { return cancelled("collapse", name: "", quiet: quiet) }
        }
        runCleanup(title: "🧲 한 화면으로 모으기", quitApps: [], quiet: quiet)
    }

    /// 🧹 깨끗하게 비우기: 가상화면을 모두 지우고 앱에 종료를 요청한다 (제자리, Finder, 항상 건드리지 않을 앱은 빼고)
    func wipe(quiet: Bool = false, ask: Bool = true) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let targets = CleanupService.quitTargets()
        if ask {
            let names = targets.compactMap(\.localizedName)
            guard confirm("가상화면 \(CleanupService.removableSpaceCount())개를 지우고 앱 \(names.count)개에 종료를 요청해요",
                          names.joined(separator: ", ") + "\n\n저장 안 한 문서가 있으면 각 앱이 저장할지 물어요. Finder와 '항상 건드리지 않을 앱'은 끄지 않아요.\n↩️ 되돌리기는 가상화면과 창 위치만 되돌리고, 끈 앱을 다시 켜지는 않아요.",
                          ok: "비우기") else { return cancelled("wipe", name: "", quiet: quiet) }
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

    /// 확인 창에서 취소함. 외부 명령이면 기다리는 쪽을 위해 결과를 남긴다
    private func cancelled(_ action: String, name: String, quiet: Bool) {
        if quiet { writeResult(ActionResult(action: action, name: name, finishedAt: Date(), ok: false, summary: "확인 창에서 취소함")) }
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
