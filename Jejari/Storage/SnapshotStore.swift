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

    static func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url(for: snapshot.name), options: .atomic)
    }

    static func load(_ name: String) throws -> Snapshot {
        try decoder.decode(Snapshot.self, from: Data(contentsOf: url(for: name)))
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
