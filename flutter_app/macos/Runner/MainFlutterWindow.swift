import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var fileManagerChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "landrop/file_manager",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "openDirectory" || call.method == "revealFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            !path.isEmpty, !path.contains("\u{0000}"),
            (path as NSString).isAbsolutePath else {
        result(FlutterError(code: "invalid_path", message: "An absolute file path is required.", details: nil))
        return
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        result(FlutterError(code: "not_found", message: "The file or folder no longer exists.", details: nil))
        return
      }
      let opensDirectory = call.method == "openDirectory"
      guard opensDirectory == isDirectory.boolValue else {
        result(FlutterError(code: "invalid_path", message: "The path has the wrong file type.", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path, isDirectory: opensDirectory)
      if opensDirectory {
        guard NSWorkspace.shared.open(url) else {
          result(FlutterError(code: "open_failed", message: "Finder could not open the folder.", details: nil))
          return
        }
      } else {
        // Reveal and select the received item; never open/execute its contents.
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
      result(nil)
    }
    fileManagerChannel = channel

    super.awakeFromNib()
  }
}
