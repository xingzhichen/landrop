#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "secure_fs.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 51;
constexpr UINT kTrayId = 1;
constexpr UINT kShowCommand = 1001;
constexpr UINT kQuitCommand = 1002;
constexpr wchar_t kDropOwner[] = L"LanDrop.DesktopShell.Owner";
const UINT kTaskbarCreated = ::RegisterWindowMessageW(L"TaskbarCreated");

std::string Utf8Path(const std::wstring& path) {
  const int size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      path.data(), static_cast<int>(path.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string utf8(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
      static_cast<int>(path.size()), utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// Accept drive-rooted and UNC filesystem paths, but never relative paths,
// URLs, or Win32 device namespaces such as \\?\ and \\.\.
bool IsAbsoluteFilesystemPath(const std::wstring& path) {
  if (path.size() >= 3 &&
      ((path[0] >= L'A' && path[0] <= L'Z') ||
       (path[0] >= L'a' && path[0] <= L'z')) &&
      path[1] == L':' && path[2] == L'\\') {
    return true;
  }
  if (path.size() < 5 || path[0] != L'\\' || path[1] != L'\\' ||
      path[2] == L'?' || path[2] == L'.') {
    return false;
  }
  const size_t server_end = path.find(L'\\', 2);
  return server_end != std::wstring::npos && server_end > 2 &&
         server_end + 1 < path.size() && path[server_end + 1] != L'\\';
}

bool DecodePath(const flutter::EncodableValue* arguments, std::wstring* path) {
  const auto* map =
      arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (!map) {
    return false;
  }
  const auto entry = map->find(flutter::EncodableValue("path"));
  if (entry == map->end()) {
    return false;
  }
  const auto* utf8 = std::get_if<std::string>(&entry->second);
  if (!utf8 || utf8->empty() || utf8->find('\0') != std::string::npos ||
      utf8->size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  const int input_length = static_cast<int>(utf8->size());
  const int wide_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8->data(), input_length, nullptr, 0);
  if (wide_length == 0) {
    return false;
  }
  path->resize(static_cast<size_t>(wide_length));
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8->data(),
                            input_length, path->data(), wide_length) !=
      wide_length) {
    return false;
  }
  std::replace(path->begin(), path->end(), L'/', L'\\');
  return IsAbsoluteFilesystemPath(*path);
}

void HandleFileManagerMethod(
    HWND window, const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool open_directory = call.method_name() == "openDirectory";
  if (!open_directory && call.method_name() != "revealFile") {
    result->NotImplemented();
    return;
  }

  std::wstring path;
  if (!DecodePath(call.arguments(), &path)) {
    result->Error("invalid_path", "Expected an absolute filesystem path in path.");
    return;
  }

  WIN32_FILE_ATTRIBUTE_DATA attributes = {};
  if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes)) {
    const DWORD error = ::GetLastError();
    const char* code = "open_failed";
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ||
        error == ERROR_INVALID_DRIVE || error == ERROR_BAD_NETPATH ||
        error == ERROR_BAD_NET_NAME) {
      code = "not_found";
    } else if (error == ERROR_INVALID_NAME || error == ERROR_BAD_PATHNAME ||
               error == ERROR_FILENAME_EXCED_RANGE) {
      code = "invalid_path";
    }
    result->Error(code, "Cannot access path (Win32 error " +
                            std::to_string(error) + ").");
    return;
  }
  const bool is_directory =
      (attributes.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  if (open_directory != is_directory) {
    result->Error("invalid_path", open_directory ? "Path is not a directory."
                                                : "Path is not a file.");
    return;
  }

  // Method handlers run on the platform/UI thread, initialized as a COM STA
  // by wWinMain. Do not change its apartment or unbalance its COM lifetime.
  if (open_directory) {
    SHELLEXECUTEINFOW execute_info = {};
    execute_info.cbSize = static_cast<DWORD>(sizeof(execute_info));
    execute_info.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
    execute_info.hwnd = window;
    execute_info.lpVerb = L"open";
    execute_info.lpFile = path.c_str();
    execute_info.nShow = SW_SHOWNORMAL;
    if (!::ShellExecuteExW(&execute_info)) {
      const DWORD error = ::GetLastError();
      result->Error("open_failed", "Cannot open directory (Win32 error " +
                                       std::to_string(error) + ").");
      return;
    }
  } else {
    PIDLIST_ABSOLUTE pidl = nullptr;
    const HRESULT parse_result =
        ::SHParseDisplayName(path.c_str(), nullptr, &pidl, 0, nullptr);
    if (FAILED(parse_result) || !pidl) {
      ::CoTaskMemFree(pidl);
      result->Error("open_failed", "Cannot resolve file (HRESULT " +
                                       std::to_string(parse_result) + ").");
      return;
    }
    // Documented cidl == 0 form: an absolute item PIDL opens its parent and
    // selects the item, without manually splitting or quoting the path.
    const HRESULT open_result =
        ::SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
    ::CoTaskMemFree(pidl);
    if (FAILED(open_result)) {
      result->Error("open_failed", "Cannot reveal file (HRESULT " +
                                       std::to_string(open_result) + ").");
      return;
    }
  }
  result->Success();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  file_manager_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "landrop/file_manager",
          &flutter::StandardMethodCodec::GetInstance());
  file_manager_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleFileManagerMethod(GetHandle(), call, std::move(result));
      });
  secure_fs_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "landrop/secure_fs",
          &flutter::StandardMethodCodec::GetInstance());
  secure_fs_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        HandleSecureFileSystemMethod(call, std::move(result));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  shell_window_ = GetHandle();
  shell_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "landrop/desktop_shell",
          &flutter::StandardMethodCodec::GetInstance());
  shell_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "initialize") {
          shell_ready_ = true;
          if (!tray_installed_ && !InstallTrayIcon()) {
            result->Error("tray_unavailable", "Cannot create notification icon; closing will exit.");
            return;
          }
          result->Success();
        } else if (call.method_name() == "showWindow") {
          ShowShellWindow();
          result->Success();
        } else if (call.method_name() == "setBackgroundMode") {
          const auto* args = call.arguments()
              ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
          const bool* enabled = nullptr;
          if (args) {
            const auto it = args->find(flutter::EncodableValue("enabled"));
            if (it != args->end()) enabled = std::get_if<bool>(&it->second);
          }
          if (!enabled) {
            result->Error("invalid_arguments", "Expected enabled boolean.");
            return;
          }
          background_mode_ = *enabled;
          if (!background_mode_ && !::IsWindowVisible(shell_window_)) ShowShellWindow();
          result->Success();
        } else if (call.method_name() == "quit") {
          result->Success();
          RequestQuit();
        } else {
          result->NotImplemented();
        }
      });
  InstallTrayIcon();
  ::DragAcceptFiles(shell_window_, TRUE);
  // The Flutter view is a child HWND and consumes messages before the runner.
  // Subclass only this owned view; normal input always chains to Flutter.
  drop_window_ = flutter_controller_->view()->GetNativeWindow();
  if (::SetPropW(drop_window_, kDropOwner, this)) {
    ::SetLastError(0);
    const LONG_PTR previous = ::SetWindowLongPtrW(
        drop_window_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(DropWindowProc));
    if (previous != 0) {
      drop_window_proc_ = reinterpret_cast<WNDPROC>(previous);
      ::DragAcceptFiles(drop_window_, TRUE);
    } else {
      ::RemovePropW(drop_window_, kDropOwner);
      drop_window_ = nullptr;
    }
  } else {
    drop_window_ = nullptr;
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (drop_window_ && ::IsWindow(drop_window_)) {
    ::DragAcceptFiles(drop_window_, FALSE);
    ::SetWindowLongPtrW(drop_window_, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(drop_window_proc_));
    ::RemovePropW(drop_window_, kDropOwner);
  }
  drop_window_ = nullptr;
  drop_window_proc_ = nullptr;
  if (shell_window_ && ::IsWindow(shell_window_)) ::DragAcceptFiles(shell_window_, FALSE);
  shell_window_ = nullptr;
  shell_ready_ = false;
  if (secure_fs_channel_) {
    secure_fs_channel_->SetMethodCallHandler(nullptr);
    secure_fs_channel_.reset();
  }
  if (shell_channel_) {
    shell_channel_->SetMethodCallHandler(nullptr);
    shell_channel_.reset();
  }
  if (file_manager_channel_) {
    file_manager_channel_->SetMethodCallHandler(nullptr);
    file_manager_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowShellWindow() {
  ::ShowWindow(shell_window_, ::IsIconic(shell_window_) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(shell_window_);
  if (shell_ready_ && shell_channel_) shell_channel_->InvokeMethod("showWindow", nullptr);
}

void FlutterWindow::RequestQuit() {
  quitting_ = true;
  // Post instead of destroying the engine while a method callback is active.
  ::PostMessageW(shell_window_, WM_CLOSE, 0, 0);
}

bool FlutterWindow::InstallTrayIcon() {
  if (!shell_window_) return false;
  NOTIFYICONDATAW icon = {};
  icon.cbSize = sizeof(icon);
  icon.hWnd = shell_window_;
  icon.uID = kTrayId;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (!icon.hIcon) icon.hIcon = ::LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
  ::lstrcpynW(icon.szTip, L"LanDrop", ARRAYSIZE(icon.szTip));
  tray_installed_ = ::Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  return tray_installed_;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_installed_) return;
  NOTIFYICONDATAW icon = {};
  icon.cbSize = sizeof(icon);
  icon.hWnd = shell_window_;
  icon.uID = kTrayId;
  ::Shell_NotifyIconW(NIM_DELETE, &icon);
  tray_installed_ = false;
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (!menu) return;
  // Unicode escapes keep this source compatible with non-UTF8 MSVC locales.
  ::AppendMenuW(menu, MF_STRING, kShowCommand, L"\u663e\u793a\u7a97\u53e3");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kQuitCommand, L"\u9000\u51fa LanDrop");
  POINT position = {};
  ::GetCursorPos(&position);
  ::SetForegroundWindow(shell_window_);
  const UINT command = ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
      position.x, position.y, 0, shell_window_, nullptr);
  ::DestroyMenu(menu);
  ::PostMessageW(shell_window_, WM_NULL, 0, 0);
  if (command == kShowCommand) ShowShellWindow();
  if (command == kQuitCommand) RequestQuit();
}

void FlutterWindow::HandleDrop(HDROP drop) {
  flutter::EncodableList paths;
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = ::DragQueryFileW(drop, index, nullptr, 0);
    if (length == 0) continue;
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    const UINT copied = ::DragQueryFileW(drop, index, path.data(), length + 1);
    path.resize(copied);
    if (!IsAbsoluteFilesystemPath(path)) continue;
    std::string utf8 = Utf8Path(path);
    if (!utf8.empty()) paths.emplace_back(std::move(utf8));
  }
  // Release the OS drop handle even if Dart isn't initialized or paths are bad.
  ::DragFinish(drop);
  if (shell_ready_ && shell_channel_ && !paths.empty()) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("paths")] = flutter::EncodableValue(std::move(paths));
    shell_channel_->InvokeMethod("filesDropped",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }
}

LRESULT CALLBACK FlutterWindow::DropWindowProc(HWND window, UINT message,
                                               WPARAM wparam, LPARAM lparam) {
  auto* owner = reinterpret_cast<FlutterWindow*>(::GetPropW(window, kDropOwner));
  if (!owner || !owner->drop_window_proc_) return ::DefWindowProcW(window, message, wparam, lparam);
  if (message == WM_DROPFILES) {
    owner->HandleDrop(reinterpret_cast<HDROP>(wparam));
    return 0;
  }
  const WNDPROC previous = owner->drop_window_proc_;
  if (message == WM_NCDESTROY) {
    ::RemovePropW(window, kDropOwner);
    owner->drop_window_ = nullptr;
    owner->drop_window_proc_ = nullptr;
  }
  return ::CallWindowProcW(previous, window, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle shell lifecycle before Flutter/plugins can consume these messages.
  if (message == WM_CLOSE) {
    if (background_mode_ && !quitting_) {
      // Never hide without a usable route to restore the window.
      if (tray_installed_ || InstallTrayIcon()) {
        ::ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
    }
    ::DestroyWindow(hwnd);
    return 0;
  }
  if (message == WM_DROPFILES) {
    HandleDrop(reinterpret_cast<HDROP>(wparam));
    return 0;
  }
  if (message == kTaskbarCreated) {
    tray_installed_ = false;
    if (!InstallTrayIcon() && !::IsWindowVisible(hwnd)) ShowShellWindow();
    return 0;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONDBLCLK) ShowShellWindow();
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) ShowTrayMenu();
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
