import AppKit
import SwiftUI
import UserNotifications

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

    func reload() {
        snapshots = SnapshotStore.all()
        checks = SettingsCheck.items()
    }

    func open(_ window: AppWindow) {
        openWindowAction?(id: window.rawValue)
        NSApp.activate()
    }

    // MARK: 외부 명령

    /// jejari://save?name=…, restore?name=…, verify?name=…, undo, status, grant, open?window=… (개발 빌드: scramble)
    /// 외부 명령은 확인 창이나 알림 없이 바로 실행하고 결과를 파일로 남긴다
    func handle(_ url: URL) {
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? "기본"
        switch url.host {
        case "save": save(name, quiet: true)
        case "restore": restore(name, quiet: true)
        case "verify": restore(name, quiet: true, verifyOnly: true)
        case "undo": restore(SnapshotStore.previousStateName, isUndo: true, quiet: true)
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

    func delete(_ name: String) {
        try? SnapshotStore.delete(name)
        reload()
    }

    // MARK: 불러오기

    /// 불러오기 직전 상태를 자동 저장하고 복원한다 (기획서 12.5). 되돌리기와 검증은 직전 상태를 저장하지 않는다
    func restore(_ name: String, isUndo: Bool = false, quiet: Bool = false, verifyOnly: Bool = false) {
        guard ensureAccessibility(quiet: quiet), !busy else { return }
        let snapshot: Snapshot
        do { snapshot = try SnapshotStore.load(name) } catch {
            status = "불러오기 실패: \(error.localizedDescription)"
            if quiet { writeResult(ActionResult(action: verifyOnly ? "verify" : "restore", name: name, finishedAt: Date(), ok: false, summary: status)) }
            return
        }
        busy = true
        status = verifyOnly ? "\"\(name)\" 검증 중…" : "\"\(name)\" 불러오는 중… 키보드와 마우스에서 손을 떼 주세요"
        Task.detached {
            if !isUndo && !verifyOnly { try? SnapshotStore.save(WindowService.capture(name: SnapshotStore.previousStateName)) }
            let log = LogBox()
            let report = Restorer(snapshot: snapshot, dryRun: verifyOnly) { message in
                log.append(message)
                Task { @MainActor in self.status = message }
            }.run()
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

    func undo() { restore(SnapshotStore.previousStateName, isUndo: true) }

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
