import CoreGraphics
import Foundation

/// 매칭에 쓰는 단서. 지금 창(LiveWindow)과 방금 찍은 창(SavedWindow)이 같이 쓴다
protocol WindowClues {
    var title: String { get }
    var identifier: String { get }
    var document: String { get }
    var order: Int { get }
    var frame: CGRect { get }
}

extension LiveWindow: WindowClues {}
extension SavedWindow: WindowClues {}

/// 저장된 창 ↔ 지금 창 매칭 (기획서 4장 창 매칭 전략)
/// macOS에는 재시작 뒤에도 유지되는 창 번호가 없고 제목도 자주 바뀌므로 여러 단서를 점수로 합친다.
enum WindowMatcher {
    /// 이 점수 이상이면 바로 배치. 미만(약한 단서만)이면 앱이 안정된 뒤에 배치
    static let strongScore = 40
    /// 창 번호로 짝지은 점수. 단서 점수로는 나올 수 없는 값
    static let idScore = 1000

    /// 저장할 때와 같은 프로세스인지. 같으면 그 앱의 창 번호가 그대로다.
    /// pid는 다시 쓰일 수 있어 실행 시각도 본다 (저장 파일의 시각은 초 단위)
    static func sameProcess(_ saved: SavedApp, pid: pid_t, launchedAt: Date?) -> Bool {
        guard let savedPid = saved.pid, let savedLaunch = saved.launchedAt, let launchedAt else { return false }
        return savedPid == pid && abs(savedLaunch.timeIntervalSince(launchedAt)) < 1
    }

    /// nil = 확실히 다른 창 (다른 파일, 다른 사이트, 다른 JetBrains 프로젝트)
    static func score(saved: SavedWindow, live: some WindowClues) -> Int? {
        var score = 0
        // 브라우저: 저장한 탭들의 사이트와 지금 보고 있는 탭(AXDocument)의 사이트를 비교
        // URL이 없는 창(프로필 선택 창, 빈 창)은 저장된 브라우저 창과 짝짓지 않는다
        let urls = saved.tabURLs
        if !urls.isEmpty {
            guard let host = URL(string: live.document)?.host else { return nil }
            let hosts = Set(urls.compactMap { URL(string: $0)?.host })
            if !hosts.contains(host) { return nil }
            score += 100
        } else if !saved.document.isEmpty && !live.document.isEmpty {
            if saved.document == live.document {
                score += 100
            } else if saved.document.hasPrefix("file:") || live.document.hasPrefix("file:") {
                return nil
            } else if let host = URL(string: saved.document)?.host, host == URL(string: live.document)?.host {
                score += 50  // 웹 주소는 페이지가 바뀌므로 사이트만 비교
            }
        }
        // 프로젝트 창은 프로젝트 창끼리만, 같은 프로젝트끼리만 (시작 화면이 프로젝트 자리로 가지 않게)
        if isProjectTitle(saved) && (!isProjectTitle(saved.bundleId, live.title) || titleKey(saved.title) != titleKey(live.title)) { return nil }
        if !saved.identifier.isEmpty && saved.identifier == live.identifier { score += 50 }
        if !saved.title.isEmpty && saved.title == live.title {
            score += 60
        } else if !titleKey(saved.title).isEmpty && titleKey(saved.title) == titleKey(live.title) {
            score += 40
        }
        if abs(saved.frame.width - live.frame.width) < 2 && abs(saved.frame.height - live.frame.height) < 2 { score += 10 }
        if abs(saved.frame.minX - live.frame.minX) < 2 && abs(saved.frame.minY - live.frame.minY) < 2 { score += 10 }
        score += max(0, 3 - abs(saved.order - live.order))
        return score
    }

    /// 제목에서 잘 바뀌지 않는 부분. "프로젝트 – 파일"이면 프로젝트, 경로 표시 " [~/...]"는 뗀다
    static func titleKey(_ title: String) -> String {
        var key = title
        for separator in [" – ", " — "] {
            if let range = key.range(of: separator) { key = String(key[..<range.lowerBound]); break }
        }
        if key.hasSuffix("]"), let range = key.range(of: " [", options: .backwards) { key = String(key[..<range.lowerBound]) }
        return key
    }

    static func isProjectTitle(_ window: SavedWindow) -> Bool { isProjectTitle(window.bundleId, window.title) }
    static func isProjectTitle(_ bundleId: String, _ title: String) -> Bool {
        bundleId.hasPrefix("com.jetbrains.") && (title.contains(" – ") || title.contains(" ["))
    }

    /// 앱 하나 안에서 짝짓는다. byID(저장할 때와 같은 프로세스)면 창 번호가 같은 창을 먼저 확정하고(idScore),
    /// 나머지는 점수가 높은 쌍부터. allowWeak가 false면 약한 단서 쌍은 건너뛴다
    static func pair<Live: WindowClues>(saved: [(index: Int, window: SavedWindow)], live: [Live], id: (Live) -> CGWindowID,
                                        byID: Bool = false, allowWeak: Bool) -> [(savedIndex: Int, liveIndex: Int, live: Live, score: Int)] {
        var candidates: [(savedIndex: Int, liveIndex: Int, score: Int)] = []
        for item in saved {
            for (liveIndex, window) in live.enumerated() {
                if byID, let savedID = item.window.windowID, savedID == id(window) {
                    candidates.append((item.index, liveIndex, idScore))
                } else if let score = score(saved: item.window, live: window) {
                    candidates.append((item.index, liveIndex, score))
                }
            }
        }
        candidates.sort { $0.score > $1.score }
        var usedSaved = Set<Int>(), usedLive = Set<Int>(), result: [(savedIndex: Int, liveIndex: Int, live: Live, score: Int)] = []
        for candidate in candidates where !usedSaved.contains(candidate.savedIndex) && !usedLive.contains(candidate.liveIndex) {
            guard candidate.score >= strongScore || allowWeak else { continue }
            usedSaved.insert(candidate.savedIndex)
            usedLive.insert(candidate.liveIndex)
            result.append((candidate.savedIndex, candidate.liveIndex, live[candidate.liveIndex], candidate.score))
        }
        return result
    }
}

extension Snapshot {
    /// 같은 이름으로 다시 저장할 때 기존 배치에서 이어받는다: 불러올 때 설정, 뺀 앱, 창마다 포함 여부.
    /// 창은 강한 단서로 짝지어진 것만 이어받는다 (약한 단서로 엉뚱한 창을 빼지 않게). 짝이 없는 새 창은 찍은 그대로
    func inheriting(from old: Snapshot) -> Snapshot {
        var result = self
        result.otherApps = old.otherApps
        result.tidySpaces = old.tidySpaces
        result.spaceStrategy = old.spaceStrategy
        let excludedApps = Set(old.apps.filter { !$0.isIncluded }.map(\.bundleId))
        for index in result.apps.indices where excludedApps.contains(result.apps[index].bundleId) {
            result.apps[index].isIncluded = false
        }
        for bundleId in Set(old.windows.map(\.bundleId)) {
            let olds = old.windows.indices.filter { old.windows[$0].bundleId == bundleId }
            let news = result.windows.indices.filter { result.windows[$0].bundleId == bundleId }
            // 앱을 끄지 않고 다시 저장했으면 창 번호로 확실히 짝짓는다
            let byID = old.apps.contains { saved in
                saved.bundleId == bundleId && result.apps.contains { new in
                    new.bundleId == bundleId && new.pid.map { WindowMatcher.sameProcess(saved, pid: $0, launchedAt: new.launchedAt) } == true
                }
            }
            let pairs = WindowMatcher.pair(saved: olds.map { ($0, old.windows[$0]) }, live: news.map { result.windows[$0] },
                                           id: { $0.windowID ?? 0 }, byID: byID, allowWeak: false)
            for pair in pairs {
                result.windows[news[pair.liveIndex]].isIncluded = old.windows[pair.savedIndex].isIncluded
            }
        }
        return result
    }
}
