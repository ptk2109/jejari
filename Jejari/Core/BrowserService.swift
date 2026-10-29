import AppKit

/// 브라우저 창의 탭 URL 읽기와 열기 (Chrome). 읽기는 AppleScript라 처음 한 번 자동화 권한 확인 창이 뜬다
enum BrowserService {
    static let chrome = "com.google.Chrome"

    /// AppleScript로 읽은 Chrome 창 하나
    struct ChromeWindow {
        var bounds: [Double]     // 좌상단 x, y, 우하단 x, y
        var activeURL: String    // 보고 있는 탭
        var urls: [String] = []
    }

    static func chromeWindows() -> [ChromeWindow] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chrome).isEmpty else { return [] }
        // tell Chrome 안에서는 tab이 Chrome의 탭 객체로 해석되므로 구분자는 문자 코드로 (0단계)
        let source = """
        tell application id "\(chrome)"
            set out to ""
            set sep to character id 9
            repeat with w in windows
                set b to bounds of w
                set out to out & "W" & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & sep & (URL of active tab of w) & linefeed
                repeat with t in tabs of w
                    set out to out & "T" & sep & (URL of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        guard let output = ExternalCommand.run("/usr/bin/osascript", ["-e", source]) else { return [] }
        var result: [ChromeWindow] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "W", fields.count >= 2 {
                result.append(ChromeWindow(bounds: fields[1].split(separator: ",").compactMap { Double($0) }, activeURL: fields.count >= 3 ? fields[2] : ""))
            } else if fields.first == "T", fields.count >= 2, !result.isEmpty {
                result[result.count - 1].urls.append(fields[1])
            }
        }
        return result
    }

    /// 지금 Chrome 창들에 탭 주소 목록을 붙인다 (짝짓기에서 탭끼리 비교). Chrome이 아니면 그대로
    static func withTabs(_ windows: [LiveWindow], bundleId: String) -> [LiveWindow] {
        guard bundleId == chrome, !windows.isEmpty else { return windows }
        let tabs = chromeWindows()
        return windows.map { window in
            var window = window
            window.tabList = urls(for: window.frame, document: window.document, in: tabs) ?? []
            return window
        }
    }

    /// AX 창에 해당하는 Chrome 창의 탭 URL. 위치가 같은 창, 없으면 보고 있는 탭이 같은 창.
    /// 다른 모니터의 창은 AppleScript 위치가 AX와 다르게 나오기도 해서 탭으로 한 번 더 찾는다 (모니터 4대에서 탭 0개로 저장됨)
    static func urls(for frame: CGRect, document: String, in windows: [ChromeWindow]) -> [String]? {
        let byBounds = windows.first {
            $0.bounds.count == 4 && abs($0.bounds[0] - frame.minX) < 2 && abs($0.bounds[1] - frame.minY) < 2 && abs($0.bounds[2] - frame.maxX) < 2
        }
        let byTab = document.isEmpty ? nil : windows.first { $0.activeURL == document }
        return (byBounds ?? byTab)?.urls
    }

    /// 새 창 하나에 URL들을 탭으로 연다 (권한 불필요).
    /// 주소는 Chrome 실행 인자로 넘어가므로 웹·파일·chrome:// 주소만 넘긴다 ("--"로 시작하는 값이 Chrome 옵션으로 읽히지 않게)
    static func openChromeWindow(_ urls: [String]) {
        let safe = urls.filter { ["http", "https", "file", "chrome"].contains(URL(string: $0)?.scheme?.lowercased()) }
        guard !safe.isEmpty else { return }
        ExternalCommand.run("/usr/bin/open", ["-na", "Google Chrome", "--args", "--new-window"] + safe)
    }
}
