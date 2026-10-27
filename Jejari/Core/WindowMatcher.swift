import CoreGraphics
import Foundation

/// 저장된 창 ↔ 지금 창 매칭 (기획서 4장 창 매칭 전략)
/// macOS에는 재시작 뒤에도 유지되는 창 번호가 없고 제목도 자주 바뀌므로 여러 단서를 점수로 합친다.
enum WindowMatcher {
    /// 이 점수 이상이면 바로 배치. 미만(약한 단서만)이면 앱이 안정된 뒤에 배치
    static let strongScore = 40

    /// nil = 확실히 다른 창 (다른 파일, 다른 사이트, 다른 JetBrains 프로젝트)
    static func score(saved: SavedWindow, live: LiveWindow) -> Int? {
        var score = 0
        if !saved.document.isEmpty && !live.document.isEmpty {
            if saved.document == live.document {
                score += 100
            } else if saved.document.hasPrefix("file:") || live.document.hasPrefix("file:") {
                return nil
            } else if let host = URL(string: saved.document)?.host, host == URL(string: live.document)?.host {
                score += 50  // 웹 주소는 페이지가 바뀌므로 사이트만 비교
            }
        }
        if isProjectTitle(saved) && isProjectTitle(saved.bundleId, live.title) && titleKey(saved.title) != titleKey(live.title) { return nil }
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

    private static func isProjectTitle(_ window: SavedWindow) -> Bool { isProjectTitle(window.bundleId, window.title) }
    private static func isProjectTitle(_ bundleId: String, _ title: String) -> Bool {
        bundleId.hasPrefix("com.jetbrains.") && (title.contains(" – ") || title.contains(" ["))
    }

    /// 앱 하나 안에서 점수가 높은 쌍부터 짝짓는다. allowWeak가 false면 약한 단서 쌍은 건너뛴다
    static func pair(saved: [(index: Int, window: SavedWindow)], live: [LiveWindow], allowWeak: Bool) -> [(savedIndex: Int, live: LiveWindow, score: Int)] {
        var candidates: [(savedIndex: Int, live: LiveWindow, score: Int)] = []
        for item in saved {
            for window in live {
                if let score = score(saved: item.window, live: window) { candidates.append((item.index, window, score)) }
            }
        }
        candidates.sort { $0.score > $1.score }
        var usedSaved = Set<Int>(), usedLive = Set<CGWindowID>(), result: [(savedIndex: Int, live: LiveWindow, score: Int)] = []
        for candidate in candidates where !usedSaved.contains(candidate.savedIndex) && !usedLive.contains(candidate.live.windowID) {
            guard candidate.score >= strongScore || allowWeak else { continue }
            usedSaved.insert(candidate.savedIndex)
            usedLive.insert(candidate.live.windowID)
            result.append(candidate)
        }
        return result
    }
}
