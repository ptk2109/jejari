import AppKit
import Combine
import Sparkle

/// 자동 업데이트 (Sparkle). 최신 GitHub Release의 appcast.xml을 확인한다 (Info.plist SUFeedURL).
/// 개발 빌드는 배포판과 번들 ID가 같아 배포판으로 덮어쓰면 안 되므로 시작하지 않는다
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum Mode: Hashable {
        case off       // 확인하지 않음
        case notify    // 확인해서 알려 주기
        case install   // 받아서 다음에 켤 때 설치
    }

    #if DEBUG
    static let isAvailable = false
    #else
    static let isAvailable = true
    #endif

    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isAvailable, updaterDelegate: nil, userDriverDelegate: nil)
        if Self.isAvailable {
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        }
    }

    var mode: Mode {
        get {
            let updater = controller.updater
            if !updater.automaticallyChecksForUpdates { return .off }
            return updater.automaticallyDownloadsUpdates ? .install : .notify
        }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue != .off
            controller.updater.automaticallyDownloadsUpdates = newValue == .install
            objectWillChange.send()
        }
    }

    /// 메뉴에서 "업데이트 확인…". 메뉴바 앱이라 앞으로 나와야 Sparkle 창이 보인다
    func checkNow() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
