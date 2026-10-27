import AppKit
import SwiftUI

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

/// 메뉴와 화면이 공유하는 상태. 창 수집과 복원은 시간이 걸리므로 백그라운드에서 돌리고 결과만 메인에서 반영한다
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var snapshotNames: [String] = []
    @Published var busy = false
    @Published var status = ""
    @Published var lastReport: RestoreReport?
    @Published var checks: [CheckItem] = []

    var canUndo: Bool { SnapshotStore.exists(SnapshotStore.previousStateName) }
    var needsAttention: Bool { checks.contains { !$0.ok && $0.required } }

    static var resultURL: URL { SnapshotStore.directory.deletingLastPathComponent().appendingPathComponent("last-result.json") }

    private init() {
        reload()
    }

    func reload() {
        snapshotNames = SnapshotStore.names()
        checks = SettingsCheck.items()
    }

    // MARK: 외부 명령

    /// jejari://save?name=…, restore?name=…, verify?name=…, undo, status, grant (개발 빌드: scramble)
    /// 외부 명령은 알림 창을 띄우지 않고 결과를 파일로 남긴다
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

    func promptSave() {
        guard ensureAccessibility(quiet: false) else { return }
        let alert = NSAlert()
        alert.messageText = "현재 배치 저장"
        alert.informativeText = "스냅샷 이름을 입력하세요. 같은 이름이 있으면 덮어씁니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = snapshotNames.first ?? "기본"
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != SnapshotStore.previousStateName else { return }
        save(name, quiet: false)
    }

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
                if !verifyOnly { self.lastReport = report }
                self.reload()
                if quiet {
                    self.writeResult(ActionResult(action: verifyOnly ? "verify" : (isUndo ? "undo" : "restore"), name: name, finishedAt: Date(),
                                                  ok: report.problems.isEmpty && report.missing.isEmpty && (!verifyOnly || report.moved.isEmpty),
                                                  summary: self.status, moved: report.moved, missing: report.missing, problems: report.problems, log: log.lines))
                } else if !verifyOnly {
                    self.showReport()
                }
            }
        }
    }

    func undo() { restore(SnapshotStore.previousStateName, isUndo: true) }

    // MARK: 결과 보고

    func showReport() {
        guard let report = lastReport else { return }
        let alert = NSAlert()
        alert.messageText = report.summary
        var lines: [String] = []
        if !report.problems.isEmpty { lines.append("⚠️ 문제\n" + report.problems.map { "• \($0)" }.joined(separator: "\n")) }
        if !report.missing.isEmpty { lines.append("❌ 찾지 못한 창\n" + report.missing.map { "• \($0)" }.joined(separator: "\n")) }
        alert.informativeText = lines.isEmpty ? "모든 창이 제자리입니다." : lines.joined(separator: "\n\n")
        NSApp.activate()
        alert.runModal()
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
