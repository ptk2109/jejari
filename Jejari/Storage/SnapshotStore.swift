import Foundation

/// 스냅샷 JSON 저장소: ~/Library/Application Support/Jejari/snapshots/<이름>.json (기획서 6장)
enum SnapshotStore {
    /// 불러오기 직전 상태를 자동 저장하는 이름 (되돌리기용, 1개만 유지. 기획서 12.5)
    static let previousStateName = "직전 상태"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jejari/snapshots", isDirectory: true)
    }

    private static func url(for name: String) -> URL {
        // 파일 이름에 쓸 수 없는 문자는 바꾼다
        let safe = name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        return directory.appendingPathComponent("\(safe).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url(for: snapshot.name), options: .atomic)
    }

    static func load(_ name: String) throws -> Snapshot {
        try decoder.decode(Snapshot.self, from: Data(contentsOf: url(for: name)))
    }

    /// 저장된 스냅샷 이름 (최근 것부터). 직전 상태는 뺀다
    static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .compactMap { (try? load($0.deletingPathExtension().lastPathComponent))?.name }
            .filter { $0 != previousStateName }
    }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(for: name).path) }

    static func delete(_ name: String) throws { try FileManager.default.removeItem(at: url(for: name)) }
}
