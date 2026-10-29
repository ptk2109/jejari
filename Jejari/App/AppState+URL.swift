import AppKit

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

/// 외부 명령: jejari://save?name=…, restore?name=…[&mode=full|arrange], verify?name=…, undo, collapse, wipe, late, status, grant, open?window=…
///
/// 웹페이지나 다른 앱도 보낼 수 있으므로 배포판에서는 위험도에 따라 나눈다.
/// - 읽기·창 열기(status, verify, open, grant): 항상
/// - 저장·불러오기·되돌리기·정리하기: 설정 "외부 명령 허용"을 켰을 때만
/// - 가상화면을 지우거나 앱을 끄는 것(collapse, wipe, 종료 요청 배치의 restore): 허용했어도 매번 확인 창
/// 개발 빌드는 시험용으로 항상 허용하고 확인하지 않는다. 결과는 파일로 남긴다
extension AppState {
    #if DEBUG
    static let isDevBuild = true
    #else
    static let isDevBuild = false
    #endif

    /// 다른 앱·스크립트가 저장·불러오기를 부를 수 있게 할지 (기본: 허용 안 함)
    static var allowsExternalCommands: Bool {
        get { isDevBuild || UserDefaults.standard.bool(forKey: "allowExternalCommands") }
        set { UserDefaults.standard.set(newValue, forKey: "allowExternalCommands") }
    }

    func handle(_ url: URL) {
        let command = url.host ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let name = query.first { $0.name == "name" }?.value ?? "기본"
        let mode = query.first { $0.name == "mode" }?.value.flatMap(RestoreMode.init) ?? .full
        let ask = !Self.isDevBuild

        if ["save", "restore", "undo", "collapse", "wipe", "late"].contains(command) && !Self.allowsExternalCommands {
            status = "외부 명령(\(command))을 막음: 설정 → 일반에서 허용할 수 있어요"
            writeResult(ActionResult(action: command, name: name, finishedAt: Date(), ok: false, summary: "외부 명령이 꺼져 있음 (설정 → 일반 → 외부 명령)"))
            return
        }

        switch command {
        case "save": save(name, quiet: true)
        case "restore": restore(name, mode: mode, quiet: true, ask: ask)
        case "verify": restore(name, quiet: true, verifyOnly: true)
        case "undo": restore(SnapshotStore.previousStateName, mode: .arrange, isUndo: true, quiet: true)
        case "collapse": collapse(quiet: true, ask: ask)
        case "late": placeLateWindows(quiet: true)
        case "wipe": wipe(quiet: true, ask: ask)
        case "grant":
            // 권한 요청 창을 띄워 손쉬운 사용 목록에 제자리를 올리고 설정 화면을 연다
            if let item = SettingsCheck.items().first(where: { $0.id == "accessibility" }) { SettingsCheck.perform(item) }
        case "open":
            // jejari://open?window=save|manage|result|settings
            let id = query.first { $0.name == "window" }?.value ?? ""
            let ready = openWindowAction != nil
            if let window = AppWindow(rawValue: id) { window == .save ? startSave() : open(window) }
            writeResult(ActionResult(action: "open", name: id, finishedAt: Date(), ok: ready && AppWindow(rawValue: id) != nil,
                                     summary: ready ? "\(id) 창 열기" : "창 여는 동작이 아직 준비되지 않음"))
        case "status":
            reload()
            writeResult(ActionResult(action: "status", name: "", finishedAt: Date(), ok: AXIsProcessTrusted(),
                                     summary: checks.map { "\($0.ok ? "✅" : "⚠️") \($0.title): \($0.detail)" }.joined(separator: "\n")))
        default:
            #if DEBUG
            if handleDebug(command, query) { return }
            #endif
            writeResult(ActionResult(action: command, name: name, finishedAt: Date(), ok: false, summary: "모르는 명령"))
        }
    }

    func writeResult(_ result: ActionResult) {
        let encoder = SnapshotStore.encoder
        try? FileManager.default.createDirectory(at: Self.resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(result).write(to: Self.resultURL, options: .atomic)
    }
}
