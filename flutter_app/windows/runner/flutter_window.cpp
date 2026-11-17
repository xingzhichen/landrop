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

namespace {

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (file_manager_channel_) {
    file_manager_channel_->SetMethodCallHandler(nullptr);
    file_manager_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
