#include "window_handle_channel.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <cmath>
#include <cstdint>
#include <optional>

namespace {

constexpr char kChannelName[] = "app.capyvibe.listenook/window_handle";
constexpr UINT_PTR kAspectSubclassId = 0x4C4E4B41;
constexpr UINT_PTR kKeepHiddenSubclassId = 0x4C4E4B48;

// DWMWA_USE_IMMERSIVE_DARK_MODE; spelled out for SDKs that predate it.
constexpr DWORD kUseImmersiveDarkMode = 20;

const flutter::EncodableValue* Arg(const flutter::EncodableMap& args,
                                   const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

std::optional<double> NumberArg(const flutter::EncodableMap& args,
                                const char* key) {
  const auto* value = Arg(args, key);
  if (!value) return std::nullopt;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) {
    return static_cast<double>(*l);
  }
  return std::nullopt;
}

bool BoolArg(const flutter::EncodableMap& args, const char* key) {
  const auto* value = Arg(args, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

// The window [args] names, if it is still a live window of this process.
HWND LiveWindow(const flutter::EncodableMap& args) {
  const auto* handle = Arg(args, "handle");
  if (!handle) return nullptr;
  HWND window =
      reinterpret_cast<HWND>(static_cast<intptr_t>(handle->LongValue()));
  DWORD owner = 0;
  if (!IsWindow(window) || GetWindowThreadProcessId(window, &owner) == 0 ||
      owner != GetCurrentProcessId()) {
    return nullptr;
  }
  return window;
}

// Keeps the client area at the locked aspect ratio while the user drags an
// edge. The ratio lives in the subclass's reference data (a double*).
LRESULT CALLBACK AspectRatioProc(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  if (message == WM_SIZING) {
    const double ratio = *reinterpret_cast<double*>(data);
    auto* rect = reinterpret_cast<RECT*>(lparam);
    RECT frame = {0, 0, 0, 0};
    AdjustWindowRectEx(
        &frame, static_cast<DWORD>(GetWindowLongPtr(window, GWL_STYLE)), FALSE,
        static_cast<DWORD>(GetWindowLongPtr(window, GWL_EXSTYLE)));
    const LONG frame_w = frame.right - frame.left;
    const LONG frame_h = frame.bottom - frame.top;
    const LONG client_w = (rect->right - rect->left) - frame_w;
    const LONG client_h = (rect->bottom - rect->top) - frame_h;
    switch (wparam) {
      case WMSZ_LEFT:
      case WMSZ_RIGHT:
      case WMSZ_BOTTOMLEFT:
      case WMSZ_BOTTOMRIGHT:
        rect->bottom = rect->top + frame_h +
                       static_cast<LONG>(std::lround(client_w / ratio));
        break;
      case WMSZ_TOP:
      case WMSZ_BOTTOM:
        rect->right = rect->left + frame_w +
                      static_cast<LONG>(std::lround(client_h * ratio));
        break;
      case WMSZ_TOPLEFT:
      case WMSZ_TOPRIGHT:
        rect->top = rect->bottom - frame_h -
                    static_cast<LONG>(std::lround(client_w / ratio));
        break;
    }
    return TRUE;
  }
  if (message == WM_NCDESTROY) {
    delete reinterpret_cast<double*>(data);
    RemoveWindowSubclass(window, AspectRatioProc, id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

void SetAspectRatio(HWND window, std::optional<double> ratio) {
  DWORD_PTR data = 0;
  if (GetWindowSubclass(window, AspectRatioProc, kAspectSubclassId, &data)) {
    RemoveWindowSubclass(window, AspectRatioProc, kAspectSubclassId);
    delete reinterpret_cast<double*>(data);
  }
  if (!ratio || !(*ratio > 0) || !std::isfinite(*ratio)) return;
  SetWindowSubclass(window, AspectRatioProc, kAspectSubclassId,
                    reinterpret_cast<DWORD_PTR>(new double(*ratio)));
}

// Refuses to show the window until Dart asks for it: Flutter shows a window it
// created once the first frame is painted, but a login-item launch or a launch
// that only opens a video must not flash the main window.
LRESULT CALLBACK KeepHiddenProc(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  if (message == WM_WINDOWPOSCHANGING) {
    auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
    position->flags &= ~SWP_SHOWWINDOW;
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, KeepHiddenProc, id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

void CenterWindow(HWND window) {
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                      &monitor)) {
    return;
  }
  RECT bounds;
  if (!GetWindowRect(window, &bounds)) return;
  const RECT& area = monitor.rcWork;
  const LONG width = bounds.right - bounds.left;
  const LONG height = bounds.bottom - bounds.top;
  SetWindowPos(window, nullptr, area.left + (area.right - area.left - width) / 2,
               area.top + (area.bottom - area.top - height) / 2, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void ShowAndActivate(HWND window) {
  RemoveWindowSubclass(window, KeepHiddenProc, kKeepHiddenSubclassId);
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window);
}

void UseDarkFrame(HWND window) {
  const BOOL dark = TRUE;
  DwmSetWindowAttribute(window, kUseImmersiveDarkMode, &dark, sizeof(dark));
}

}  // namespace

WindowHandleChannel::WindowHandleChannel(
    flutter::FlutterEngine* engine, std::function<void(HWND)> on_main_window)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          engine->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance())),
      on_main_window_(std::move(on_main_window)) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

WindowHandleChannel::~WindowHandleChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void WindowHandleChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  HWND window = args ? LiveWindow(*args) : nullptr;
  if (!window) {
    // Destroyed already, or never one of ours: nothing to do.
    result->Success();
    return;
  }
  const std::string& method = call.method_name();
  if (method == "hide") {
    ShowWindow(window, SW_HIDE);
  } else if (method == "show") {
    ShowAndActivate(window);
  } else if (method == "setAspectRatio") {
    SetAspectRatio(window, NumberArg(*args, "aspectRatio"));
  } else if (method == "startDrag") {
    // Reply first: the move loop below runs until the button is released.
    result->Success();
    const int primary =
        GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
    if (GetAsyncKeyState(primary) & 0x8000) {
      // The Flutter view holds mouse capture for the drag it recognized;
      // hand the gesture to the window as a title-bar press instead.
      ReleaseCapture();
      SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }
    return;
  } else if (method == "center") {
    CenterWindow(window);
  } else if (method == "registerMainWindow") {
    if (BoolArg(*args, "startHidden")) {
      ShowWindow(window, SW_HIDE);
      SetWindowSubclass(window, KeepHiddenProc, kKeepHiddenSubclassId, 0);
    }
    // Flutter draws the main window's title bar and caption buttons (see
    // AppWindowToolbar). Keep the resize frame and system menu.
    const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
    SetWindowLongPtr(window, GWL_STYLE, style & ~WS_CAPTION);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
    CenterWindow(window);
    if (on_main_window_) on_main_window_(window);
  } else if (method == "stylePlayerWindow") {
    // The native caption stays: it shows the file name.
    UseDarkFrame(window);
  } else if (method == "setSkipTaskbar" || method == "setTitlebarVisible") {
    // A hidden window has no taskbar button, and the player keeps its native
    // caption on Windows.
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}
