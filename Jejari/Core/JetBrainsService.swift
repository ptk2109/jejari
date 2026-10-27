import Foundation

/// JetBrains IDE(PhpStorm, DataGrip …) 프로젝트 열기. 창 제목의 프로젝트명으로 최근 프로젝트 목록에서 경로를 찾는다 (0단계 검증)
enum JetBrainsService {
    static func isJetBrains(_ bundleId: String) -> Bool { bundleId.hasPrefix("com.jetbrains.") }

    /// ~/Library/Application Support/JetBrains/<앱 이름><버전>/options/recentProjects.xml 중 가장 최근 버전에서 찾는다
    static func projectPath(appName: String, project: String) -> String? {
        guard !project.isEmpty else { return nil }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/JetBrains")
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix(appName) }.sorted()
        let pattern = try? NSRegularExpression(pattern: #"<entry key="([^"]+)">"#)
        for folder in folders.reversed() {
            guard let xml = try? String(contentsOf: base.appendingPathComponent("\(folder)/options/recentProjects.xml"), encoding: .utf8),
                  let pattern else { continue }
            for match in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                guard let range = Range(match.range(at: 1), in: xml) else { continue }
                let path = String(xml[range]).replacingOccurrences(of: "$USER_HOME$", with: NSHomeDirectory())
                if (path as NSString).lastPathComponent == project { return path }
            }
        }
        return nil
    }

    /// 프로젝트를 연다. 한꺼번에 여러 개를 보내면 하나만 열린 적이 있어 호출하는 쪽에서 하나씩 연다 (0단계)
    static func open(project path: String, appPath: String) {
        ExternalCommand.openInBackground(app: appPath, [path])
    }
}
