#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include <shellapi.h>

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleDrop(HDROP drop);
  void ShowShellWindow();
  bool InstallTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void RequestQuit();
  static LRESULT CALLBACK DropWindowProc(HWND window, UINT message,
                                         WPARAM wparam, LPARAM lparam);
  HWND shell_window_ = nullptr;
  HWND drop_window_ = nullptr;
  WNDPROC drop_window_proc_ = nullptr;
  bool background_mode_ = true;
  bool quitting_ = false;
  bool tray_installed_ = false;
  bool shell_ready_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Keep the channel alive, and destroy it before its engine/messenger.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      file_manager_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> shell_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
