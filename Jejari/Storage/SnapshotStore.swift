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
        directory.appendingPathComponent("\(fileName(name)).json")
    }

    /// 파일 이름에 쓸 수 없는 문자는 바꾼다 (폴더를 넘나들지 않게)
    static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
    }

    static let encoder: JSONEncoder = {
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

    /// 창 번호와 프로세스는 앱이 켜져 있는 동안에만 맞으므로 배치에는 남기지 않는다 (MatchCache). 직전 상태는 곧 되돌리기에 쓰여서 남긴다
    static func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = snapshot.name == previousStateName ? snapshot : snapshot.withoutSession()
        try encoder.encode(stored).write(to: url(for: snapshot.name), options: .atomic)
    }

    /// 배치는 창 번호 없이(0.6.0으로 저장한 파일에 있어도 버림), 직전 상태는 그 프로세스가 아직 떠 있는 창 번호만
    static func load(_ name: String) throws -> Snapshot {
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: url(for: name)))
        return name == previousStateName ? snapshot.keepingLiveSession() : snapshot.withoutSession()
    }

    /// 짝짓기에 쓸 배치: 마지막으로 불러올 때 짝지은 창 번호 중 아직 맞는 것을 붙인다
    static func loadForMatching(_ name: String) throws -> Snapshot {
        let snapshot = try load(name)
        return name == previousStateName ? snapshot : MatchCache.apply(to: snapshot)
    }

    /// 저장된 스냅샷 (최근 것부터). 직전 상태는 뺀다
    static func all() -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Snapshot.self, from: Data(contentsOf: $0)) }
            .filter { $0.name != previousStateName }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func names() -> [String] { all().map(\.name) }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(for: name).path) }

    static func delete(_ name: String) throws { try FileManager.default.removeItem(at: url(for: name)) }

    /// 이름 바꾸기. 같은 이름이 이미 있으면 실패
    static func rename(_ name: String, to newName: String) throws {
        guard !exists(newName) else { throw CocoaError(.fileWriteFileExists) }
        var snapshot = try load(name)
        snapshot.name = newName
        try save(snapshot)
        try delete(name)
    }
}
