import AppKit

/// 브라우저 창의 탭 URL 읽기와 열기 (Chrome). 읽기는 AppleScript라 처음 한 번 자동화 권한 확인 창이 뜬다
enum BrowserService {
    static let chrome = "com.google.Chrome"

    /// Chrome 창마다 (bounds = 좌상단 x, y, 우하단 x, y, 탭 URL)
    static func chromeWindows() -> [(bounds: [Double], urls: [String])] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chrome).isEmpty else { return [] }
        // tell Chrome 안에서는 tab이 Chrome의 탭 객체로 해석되므로 구분자는 문자 코드로 (0단계)
        let source = """
        tell application id "\(chrome)"
            set out to ""
            set sep to character id 9
            repeat with w in windows
                set b to bounds of w
                set out to out & "W" & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & linefeed
                repeat with t in tabs of w
                    set out to out & "T" & sep & (URL of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        var result: [(bounds: [Double], urls: [String])] = []
        for line in (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "W", fields.count >= 2 {
                result.append((fields[1].split(separator: ",").compactMap { Double($0) }, []))
            } else if fields.first == "T", fields.count >= 2, !result.isEmpty {
                result[result.count - 1].urls.append(fields[1])
            }
        }
        return result
    }

    /// 창 위치가 같은 Chrome 창의 탭 URL
    static func urls(for frame: CGRect, in windows: [(bounds: [Double], urls: [String])]) -> [String]? {
        windows.first {
            $0.bounds.count == 4 && abs($0.bounds[0] - frame.minX) < 2 && abs($0.bounds[1] - frame.minY) < 2 && abs($0.bounds[2] - frame.maxX) < 2
        }?.urls
    }

    /// 새 창 하나에 URL들을 탭으로 연다 (권한 불필요)
    static func openChromeWindow(_ urls: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Google Chrome", "--args", "--new-window"] + urls
        try? process.run()
        process.waitUntilExit()
    }
}
