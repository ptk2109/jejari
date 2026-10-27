import Foundation

/// 불러오기 기록: 직전 상태, 결과와 진행 로그, 불러온 뒤 상태를 남겨 결과를 추적한다. 설정 → 일반에서 끌 수 있다
enum RunLogStore {
    static let keep = 20

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "debugLogging") as? Bool ?? true }
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

    /// logs/<시각>-<배치 이름>/ 에 before.json, report.json, after.json
    static func record(_ entry: Entry, before: Snapshot?, after: Snapshot?) {
        let encoder = SnapshotStore.encoder
        let stamp = entry.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.dash))
        let folder = directory.appendingPathComponent("\(stamp)-\(SnapshotStore.fileName(entry.snapshot))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? encoder.encode(entry).write(to: folder.appendingPathComponent("report.json"))
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
