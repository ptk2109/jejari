import Foundation

/// 불러오기 기록: 직전 상태, 결과와 진행 로그, 불러온 뒤 상태를 남겨 결과를 추적한다. 설정 → 일반에서 켜고 끈다.
/// 창 제목·문서 경로·탭 주소가 들어가므로 배포판은 기본으로 남기지 않는다 (문제를 알려 줄 때 켬). 개발 빌드는 기본으로 남긴다.
/// 자세한 진단 기록을 더할 때도 이 설정이 켜져 있을 때만 남긴다
enum RunLogStore {
    static let keep = 20

    #if DEBUG
    private static let enabledByDefault = true
    #else
    private static let enabledByDefault = false
    #endif

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "debugLogging") as? Bool ?? enabledByDefault }
        set { UserDefaults.standard.set(newValue, forKey: "debugLogging") }
    }

    static var directory: URL { SnapshotStore.directory.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true) }

    struct Entry: Codable {
        var snapshot: String
        var mode: String
        var startedAt: Date
        var finishedAt: Date
        var report: RestoreReport
        var log: [String]
    }

    /// logs/<시각>-<배치 이름>/ 에 snapshot.json(불러온 배치), before.json, report.json, after.json.
    /// snapshot과 before, report의 짝(matches)으로 짝짓기를 다시 돌려 볼 수 있다 (jejari://replay)
    static func record(_ entry: Entry, snapshot: Snapshot, before: Snapshot?, after: Snapshot?) {
        let encoder = SnapshotStore.encoder
        let stamp = entry.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.dash))
        let folder = directory.appendingPathComponent("\(stamp)-\(SnapshotStore.fileName(entry.snapshot))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? encoder.encode(entry).write(to: folder.appendingPathComponent("report.json"))
        try? encoder.encode(snapshot).write(to: folder.appendingPathComponent("snapshot.json"))
        if let before { try? encoder.encode(before).write(to: folder.appendingPathComponent("before.json")) }
        if let after { try? encoder.encode(after).write(to: folder.appendingPathComponent("after.json")) }
        prune()
    }

    private static func prune() {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in folders.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}
