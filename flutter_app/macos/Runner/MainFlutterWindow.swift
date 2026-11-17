import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate, NSDraggingDestination {
  private var fileManagerChannel: FlutterMethodChannel?
  private var shellChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var backgroundMode = true
  private var shellReady = false

  func showShellWindow() {
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if shellReady { shellChannel?.invokeMethod("showWindow", arguments: nil) }
  }

  @objc private func showFromMenu(_ sender: Any?) { showShellWindow() }
  @objc private func quitFromMenu(_ sender: Any?) { NSApp.terminate(nil) }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if backgroundMode {
      // Do not close/destroy the Flutter engine: transfers keep running.
      orderOut(nil)
    } else {
      NSApp.terminate(nil)
    }
    return false
  }

  private func installDesktopShell(_ controller: FlutterViewController) {
    delegate = self
    isReleasedWhenClosed = false
    let channel = FlutterMethodChannel(
      name: "landrop/desktop_shell", binaryMessenger: controller.engine.binaryMessenger)
    shellChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "initialize":
        self.shellReady = true
        result(nil)
      case "showWindow":
        self.showShellWindow()
        result(nil)
      case "setBackgroundMode":
        guard let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool else {
          result(FlutterError(code: "invalid_arguments", message: "Expected enabled boolean.", details: nil))
          return
        }
        self.backgroundMode = enabled
        if !enabled && !self.isVisible { self.showShellWindow() }
        result(nil)
      case "quit":
        result(nil)
        // Reply before terminating the engine and its messenger.
        DispatchQueue.main.async { NSApp.terminate(nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "LanDrop")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "LanDrop — 关闭窗口后仍在后台运行"
    }
    let menu = NSMenu()
    let show = menu.addItem(withTitle: "显示窗口", action: #selector(showFromMenu(_:)), keyEquivalent: "")
    show.target = self
    menu.addItem(NSMenuItem.separator())
    let quit = menu.addItem(withTitle: "退出 LanDrop", action: #selector(quitFromMenu(_:)), keyEquivalent: "")
    quit.target = self
    item.menu = menu
    statusItem = item

    // Register the window itself: AppKit uses it when the Flutter child view
    // does not register for file URLs. No overlay intercepts clicks or drawing.
    registerForDraggedTypes([.fileURL])
  }

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
    installDesktopShell(flutterViewController)
  }

  private func dragChanged(_ dragging: Bool) {
    if shellReady { shellChannel?.invokeMethod("dragChanged", arguments: ["dragging": dragging]) }
  }

  private func filePaths(_ sender: NSDraggingInfo) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    var seen = Set<String>()
    return urls.filter { $0.isFileURL }.map { $0.standardizedFileURL.path }.filter {
      ($0 as NSString).isAbsolutePath && !$0.contains("\u{0000}") && seen.insert($0).inserted
    }
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let accepts = !filePaths(sender).isEmpty
    dragChanged(accepts)
    return accepts ? .copy : []
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    !filePaths(sender).isEmpty ? .copy : []
  }

  func draggingExited(_ sender: NSDraggingInfo?) { dragChanged(false) }
  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !filePaths(sender).isEmpty }
  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dragChanged(false)
    let paths = filePaths(sender)
    guard !paths.isEmpty else { return false }
    guard shellReady else { return false }
    shellChannel?.invokeMethod("filesDropped", arguments: ["paths": paths])
    return true
  }
  func concludeDragOperation(_ sender: NSDraggingInfo?) { dragChanged(false) }
}
