import Cocoa
import Darwin
import FlutterMacOS

@NSApplicationMain
class AppDelegate: FlutterAppDelegate {
  override init() {
    // Finder 双击启动时，进程的 stdout/stderr 接到 launchd pipe，用户会话很早关闭读端；
    // Flutter 引擎 release 模式下任何一次 write 都会触发 SIGPIPE，默认 handler 立即 kill
    // (waitpid status=13)。命令行 open / NSWorkspace 启动不会复现，因为 stderr 继承自 caller。
    signal(SIGPIPE, SIG_IGN)
    super.init()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}
