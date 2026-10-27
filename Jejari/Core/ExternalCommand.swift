import Foundation

/// 다른 프로그램(open, osascript)을 실행하고 끝날 때까지 기다린다
enum ExternalCommand {
    /// 표준 출력을 돌려준다. 실행하지 못하면 nil.
    /// 출력을 다 읽은 뒤에 기다린다: 출력이 파이프 버퍼(64KB)보다 크면 먼저 기다릴 때 서로 멈추기 때문 (탭이 많은 Chrome)
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// open -g -a <앱> [파일…]: 앞으로 가져오지 않고 연다
    static func openInBackground(app: String, _ items: [String] = []) {
        run("/usr/bin/open", ["-g", "-a", app] + items)
    }
}
