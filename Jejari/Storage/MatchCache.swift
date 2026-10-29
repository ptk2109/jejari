import AppKit

/// 배치마다 마지막으로 불러올 때 짝지은 창 번호. Application Support/Jejari/matches.json
///
/// 창 번호(CGWindowID)는 그 앱이 켜져 있는 동안에만 맞는다. 오래 두고 쓰는 배치 파일에 넣으면 재부팅 뒤에는 쓸모없고
/// 다른 창에 다시 쓰인 번호를 믿을 수도 있어서, 배치에는 넣지 않고 여기에 따로 둔다.
/// 다음에 불러오거나 다시 저장할 때 그 앱 프로세스(pid, 시작 시각)가 아직 떠 있는 짝만 쓴다
///
/// 생명주기
/// - 생김: 불러오기(검증·되돌리기 제외)가 끝날 때 그 배치의 기억을 통째로 새로 쓴다. 확실한 짝(창 번호, 강한 단서)만
/// - 안 씀: 프로세스가 끝났거나 다시 시작됨 / 그 번호의 창이 지금 그 프로세스 것이 아님 / 배치를 다시 저장함(저장 시각이 다름)
/// - 지움: 기억을 새로 쓸 때 위처럼 못 쓰게 된 짝과 지운 배치의 기억을 같이 지운다
enum MatchCache {
    struct Entry: Codable {
        var window: Int            // 배치의 windows 안 번호
        var windowID: CGWindowID
        var pid: Int32
        var startedAt: Date
    }

    struct Record: Codable {
        var createdAt: Date        // 배치를 저장한 시각. 다시 저장하면 창 목록이 바뀌므로 맞지 않는 기억은 버린다
        var entries: [Entry]
    }

    static var url: URL { SnapshotStore.directory.deletingLastPathComponent().appendingPathComponent("matches.json") }

    private static func all() -> [String: Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: Record].self, from: $0) } ?? [:]
    }

    /// 불러오기 결과의 짝을 기억한다. matches의 saved는 includedWindows 안 번호.
    /// 약한 단서로 추측한 짝은 기억하지 않는다. 틀렸다면 다음부터 창 번호로 "확정"되어 앱을 끌 때까지 계속 틀리게 되므로
    static func remember(_ snapshot: Snapshot, matches: [RestoreReport.MatchRecord]) {
        let included = snapshot.windows.indices.filter { snapshot.windows[$0].isIncluded }
        let entries = matches.compactMap { match -> Entry? in
            guard match.score >= WindowMatcher.strongScore, included.indices.contains(match.saved),
                  let startedAt = WindowService.startTime(of: match.pid) else { return nil }
            return Entry(window: included[match.saved], windowID: match.windowID, pid: match.pid, startedAt: startedAt)
        }
        var records = all()
        records[snapshot.name] = Record(createdAt: snapshot.createdAt, entries: entries)
        // 지운 배치의 기억, 프로세스가 끝나 못 쓰게 된 짝은 지운다
        let names = Set(SnapshotStore.names())
        let owners = windowOwners()
        records = records.filter { names.contains($0.key) }.mapValues { record in
            var kept = record
            kept.entries = record.entries.filter { owners[$0.windowID] == $0.pid && isAlive($0) }
            return kept
        }
        try? SnapshotStore.encoder.encode(records).write(to: url, options: .atomic)
    }

    /// 기억한 짝 중 아직 맞는 것만 배치의 창에 창 번호로 붙인다. 맞는지는 세 가지를 모두 본다:
    /// 그 pid의 프로세스가 같은 시각에 시작된 것(pid는 다시 쓰인다), 그 프로세스가 배치의 창과 같은 앱, 그 번호의 창이 지금 그 프로세스 것
    static func apply(to snapshot: Snapshot) -> Snapshot {
        guard let record = all()[snapshot.name], abs(record.createdAt.timeIntervalSince(snapshot.createdAt)) < 1 else { return snapshot }
        var result = snapshot
        let owners = windowOwners()
        var used = Set<CGWindowID>()
        for entry in record.entries where result.windows.indices.contains(entry.window) && !used.contains(entry.windowID) {
            guard isAlive(entry), owners[entry.windowID] == entry.pid,
                  NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier == result.windows[entry.window].bundleId else { continue }
            result.windows[entry.window].windowID = entry.windowID
            used.insert(entry.windowID)
        }
        return result
    }

    /// 같은 pid의 프로세스가 기억할 때와 같은 시각에 시작된 것인지 (커널 기록, 파일에는 초 단위로 남아 1초 안이면 같음)
    private static func isAlive(_ entry: Entry) -> Bool {
        guard let now = WindowService.startTime(of: entry.pid) else { return false }
        return abs(now.timeIntervalSince(entry.startedAt)) < 1
    }

    /// 지금 있는 창 번호 → 그 창을 가진 pid (모든 가상화면, 권한 없이)
    static func windowOwners() -> [CGWindowID: Int32] {
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return Dictionary(list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            return (id, pid)
        }, uniquingKeysWith: { first, _ in first })
    }
}

extension Snapshot {
    /// 창 번호와 프로세스를 뺀다. 오래 두는 배치 파일에 남기지 않는다 (MatchCache)
    func withoutSession() -> Snapshot {
        var result = self
        for i in result.windows.indices { result.windows[i].windowID = nil }
        for i in result.apps.indices { result.apps[i].pid = nil; result.apps[i].launchedAt = nil }
        return result
    }

    /// 저장할 때의 프로세스가 아직 떠 있고 그 창 번호가 지금도 그 프로세스 것인 창만 번호를 남긴다. 직전 상태처럼 곧 다시 쓰는 것에 쓴다
    func keepingLiveSession() -> Snapshot {
        var result = self
        // 앱 → 아직 떠 있는 그때의 pid
        var livePids: [String: Set<Int32>] = [:]
        for app in apps {
            guard let pid = app.pid, let saved = app.launchedAt, let now = WindowService.startTime(of: pid),
                  abs(now.timeIntervalSince(saved)) < 1 else { continue }
            livePids[app.bundleId, default: []].insert(pid)
        }
        let owners = MatchCache.windowOwners()
        for i in result.windows.indices {
            if let id = result.windows[i].windowID, let owner = owners[id], livePids[result.windows[i].bundleId]?.contains(owner) == true { continue }
            result.windows[i].windowID = nil
        }
        return result
    }
}
