import AppKit
// 시험 앱: 실행하거나 다시 열기 요청을 받으면 delay초 뒤에 창 count개를 겹쳐 띄운다
// defaults write com.jejari.test.latewin delay -int 40 ; count -int 2
final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var made = 0
    func open() {
        let d = UserDefaults.standard
        let delay = d.integer(forKey: "delay"), count = max(d.integer(forKey: "count"), 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) {
            for i in 0..<count {
                self.made += 1
                let w = NSWindow(contentRect: NSRect(x: 200 + 40 * i, y: 300 - 40 * i, width: 500, height: 320),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                w.title = "LateWin \(self.made)"
                w.isReleasedWhenClosed = false
                w.orderFront(nil)
                self.windows.append(w)
            }
        }
    }
    func applicationDidFinishLaunching(_ n: Notification) { open() }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { open() }
        return false
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
