import CoreGraphics
import Foundation

/// 저장된 배치 하나. 좌표는 모두 CG 전역 좌표(주 모니터 좌상단 원점, 포인트 단위)
struct Snapshot: Codable, Identifiable {
    var id: String { name }
    var name: String
    var createdAt: Date
    var displays: [SavedDisplay]
    var spaces: [SavedDisplaySpaces]
    var apps: [SavedApp]
    var windows: [SavedWindow]
}

struct SavedDisplay: Codable, Hashable {
    var uuid: String
    var name: String
    var frame: CGRect
    var isMain: Bool
    var scale: Double
}

/// 모니터 하나의 Space 구성 (순서 = 모니터 안 번호)
struct SavedDisplaySpaces: Codable {
    var displayUuid: String
    var spaces: [SavedSpace]
}

struct SavedSpace: Codable {
    var index: Int        // 모니터 안 번호 (1부터)
    var uuid: String
    var type: Int         // 0 = 데스크톱, 4 = 전체 화면
    var isCurrent: Bool
}

/// 저장할 때 실행 중이던 일반 앱 (창이 없어도 기록. 기획서 12.6)
struct SavedApp: Codable {
    var bundleId: String
    var name: String
    var path: String
}

/// 창 하나와 매칭 단서 (기획서 4장 창 매칭 전략)
struct SavedWindow: Codable {
    var bundleId: String
    var appName: String
    var title: String
    var identifier: String     // AXIdentifier (일부 앱만)
    var document: String       // AXDocument: 문서 경로 또는 URL (일부 앱만)
    var order: Int             // 앱 안 순서
    var frame: CGRect
    var displayUuid: String
    var spaceIndex: Int
    var spaceUuid: String
    var minimized: Bool
    var fullScreen: Bool
}
