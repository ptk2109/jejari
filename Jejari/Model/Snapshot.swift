import CoreGraphics
import Foundation

/// 저장된 배치 하나. 좌표는 모두 CG 전역 좌표(주 모니터 좌상단 원점, 포인트 단위)
/// 불러올 때 스냅샷에 없는 앱을 어떻게 할지 (기획서 12.1, 12.2 #4). 배치마다 정한다
enum OtherAppsPolicy: String, Codable, CaseIterable {
    case keep       // 그대로 둠
    case collect    // 보관 화면으로 모으기 (모니터마다 필요한 화면 뒤의 가상화면 하나)
    case hide       // 숨기기 (⌘H)
    case quit       // 종료 요청 (⌘Q, 확인 후)

    var title: String {
        switch self {
        case .keep: "그대로 둠"
        case .collect: "보관 화면으로"
        case .hide: "숨기기"
        case .quit: "종료 요청"
        }
    }
}

struct Snapshot: Codable, Identifiable {
    var id: String { name }
    var name: String
    var createdAt: Date
    /// 다른 앱 처리. nil이면 그대로 둠 (예전 파일과 호환)
    var otherApps: OtherAppsPolicy? = nil
    /// 남는 가상화면 정리: 필요한 화면 뒤의 남는 화면의 창을 보관 화면 하나로 모으고 빈 화면을 지운다. nil이면 끔
    var tidySpaces: Bool? = nil
    var displays: [SavedDisplay]
    var spaces: [SavedDisplaySpaces]
    var apps: [SavedApp]
    var windows: [SavedWindow]

    var includedWindows: [SavedWindow] { windows.filter(\.isIncluded) }

    var otherAppsPolicy: OtherAppsPolicy {
        get { otherApps ?? .keep }
        set { otherApps = newValue == .keep ? nil : newValue }
    }

    /// 이 배치에 포함된 앱 (포함된 창이 있거나, 창 없이 실행 중이던 앱 중 빼지 않은 것)
    var includedBundleIds: Set<String> {
        let windowless = Set(windowlessAppIndexes.map { apps[$0].bundleId })
        return Set(includedWindows.map(\.bundleId)).union(apps.filter { windowless.contains($0.bundleId) && $0.isIncluded }.map(\.bundleId))
    }

    /// 창이 하나도 없는 실행 중인 앱의 인덱스
    var windowlessAppIndexes: [Int] {
        let withWindows = Set(windows.map(\.bundleId))
        return apps.indices.filter { !withWindows.contains(apps[$0].bundleId) }
    }
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
    /// 사용자가 뺀 앱. nil이면 포함 (예전 파일과 호환)
    var excluded: Bool? = nil

    var isIncluded: Bool {
        get { excluded != true }
        set { excluded = newValue ? nil : true }
    }
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
    /// 브라우저 창의 탭 URL (Chrome, AppleScript로 읽음). 다른 앱은 nil
    var urls: [String]? = nil
    /// 사용자가 뺀 창. 지우지 않고 표시만 해서 나중에 다시 포함할 수 있게 한다. nil이면 포함 (예전 파일과 호환)
    var excluded: Bool? = nil

    var isIncluded: Bool {
        get { excluded != true }
        set { excluded = newValue ? nil : true }
    }
}
