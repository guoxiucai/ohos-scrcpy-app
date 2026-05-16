import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 标题栏留空（应用品牌已在主页内自绘）
    self.title = ""

    RegisterGeneratedPlugins(registry: flutterViewController)
    VideoDecoderPlugin.register(
      with: flutterViewController.registrar(forPlugin: "VideoDecoderPlugin"))

    super.awakeFromNib()
  }
}
