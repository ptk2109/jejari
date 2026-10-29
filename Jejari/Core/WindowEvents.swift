import AppKit

/// 앱들의 창이 생기거나 제목이 바뀌면 기다리는 쪽을 바로 깨운다 (AXObserver).
/// 불러오기가 창을 몇 초마다 다시 훑으며 "다 떴나"를 짐작하던 것을, 창이 생긴 순간 반응하게 한다.
/// 알림을 주지 않는 앱도 있어 기다리는 쪽은 제한 시간을 함께 둔다
final class WindowEvents: @unchecked Sendable {
    private let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observers: [pid_t: AXObserver] = [:]
    private var lastCreated: [pid_t: Date] = [:]
    private var runLoop: CFRunLoop?

    /// 알림은 별도 스레드의 런루프에서 받는다 (불러오기는 백그라운드에서 돌고, 메인 스레드를 붙잡지 않게)
    init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // 소스가 하나도 없으면 런루프가 바로 끝나므로 빈 타이머로 붙잡아 둔다
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "jejari.window-events"
        thread.start()
        ready.wait()
    }

    /// 그 앱의 창 알림을 받기 시작한다 (같은 앱은 한 번만)
    func watch(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard observers[pid] == nil, let runLoop else { return }
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let created = (notification as String) == kAXWindowCreatedNotification
            Unmanaged<WindowEvents>.fromOpaque(refcon).takeUnretainedValue().received(pid, created: created)
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXTitleChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        CFRunLoopWakeUp(runLoop)
        observers[pid] = observer
    }

    /// 어떤 알림이든 기다리는 쪽을 깨운다. 시각은 창이 생겼을 때만 남긴다 (제목은 시계가 도는 터미널처럼 계속 바뀌는 앱이 있어서)
    private func received(_ pid: pid_t, created: Bool) {
        if created { lock.withLock { lastCreated[pid] = Date() } }
        signal.signal()
    }

    /// 그 앱에서 마지막으로 창이 생긴 시각
    func lastCreated(of pid: pid_t) -> Date? { lock.withLock { lastCreated[pid] } }

    /// 알림이 오거나 timeout이 지날 때까지 기다린다. 알림이 왔으면 창이 크기·제목을 잡도록 잠깐 더 기다리고 쌓인 알림은 비운다
    @discardableResult
    func wait(timeout: TimeInterval) -> Bool {
        guard signal.wait(timeout: .now() + timeout) == .success else { return false }
        usleep(300_000)
        while signal.wait(timeout: .now()) == .success {}
        return true
    }

    /// 알림을 그만 받고 스레드를 끝낸다
    func stop() {
        lock.withLock {
            for observer in observers.values { CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
            observers.removeAll()
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}
