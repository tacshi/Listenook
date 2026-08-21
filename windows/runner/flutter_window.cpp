#include "flutter_window.h"

#include <commctrl.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/standard_method_codec.h"

namespace {

constexpr char kTranscriptCursorChannel[] =
    "app.meowstt.desktop/transcript_structure_cursor";
constexpr UINT_PTR kTranscriptCursorSubclassId = 0x4D535443;

const flutter::EncodableValue* MapValue(
    const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

std::optional<int64_t> IntegerValue(const flutter::EncodableValue* value) {
  if (!value) {
    return std::nullopt;
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    return *integer;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return *integer;
  }
  return std::nullopt;
}

struct CursorLine {
  double x1;
  double y1;
  double x2;
  double y2;
};

double DistanceToLine(double x, double y, const CursorLine& line) {
  const double dx = line.x2 - line.x1;
  const double dy = line.y2 - line.y1;
  const double length_squared = dx * dx + dy * dy;
  const double amount = length_squared == 0.0
                            ? 0.0
                            : std::clamp(((x - line.x1) * dx +
                                          (y - line.y1) * dy) /
                                             length_squared,
                                         0.0, 1.0);
  const double nearest_x = line.x1 + amount * dx;
  const double nearest_y = line.y1 + amount * dy;
  return std::hypot(x - nearest_x, y - nearest_y);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {
  if (flutter_view_window_ && transcript_cursor_subclassed_) {
    RemoveWindowSubclass(flutter_view_window_, TranscriptCursorSubclassProc,
                         kTranscriptCursorSubclassId);
  }
  DestroyTranscriptStructureCursors();
}

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
  flutter_view_window_ = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(flutter_view_window_);
  RegisterTranscriptStructureCursor();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  DeactivateAllTranscriptStructureCursors();
  transcript_cursor_channel_.reset();
  if (flutter_view_window_ && transcript_cursor_subclassed_) {
    RemoveWindowSubclass(flutter_view_window_, TranscriptCursorSubclassProc,
                         kTranscriptCursorSubclassId);
    transcript_cursor_subclassed_ = false;
  }
  flutter_view_window_ = nullptr;
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
    case WM_KILLFOCUS:
    case WM_MOUSELEAVE:
      DeactivateAllTranscriptStructureCursors();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::RegisterTranscriptStructureCursor() {
  transcript_cursor_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kTranscriptCursorChannel,
          &flutter::StandardMethodCodec::GetInstance());
  transcript_cursor_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "deactivateAll") {
          DeactivateAllTranscriptStructureCursors();
          result->Success();
          return;
        }
        if (!arguments) {
          result->Error("invalid_cursor_arguments",
                        "Cursor arguments are required.");
          return;
        }
        const auto session = IntegerValue(MapValue(*arguments, "session"));
        if (!session) {
          result->Error("invalid_cursor_arguments",
                        "A cursor session is required.");
          return;
        }
        if (call.method_name() == "deactivate") {
          DeactivateTranscriptStructureCursor(*session);
          result->Success();
          return;
        }
        if (call.method_name() != "activate") {
          result->NotImplemented();
          return;
        }
        const auto* kind_value = MapValue(*arguments, "kind");
        const auto* kind = kind_value
                               ? std::get_if<std::string>(kind_value)
                               : nullptr;
        if (!kind || (*kind != "split" && *kind != "merge")) {
          result->Error("invalid_cursor_arguments",
                        "A split or merge cursor kind is required.");
          return;
        }
        if (!transcript_cursor_subclassed_ ||
            !ActivateTranscriptStructureCursor(
                *kind == "split" ? TranscriptCursorKind::kSplit
                                 : TranscriptCursorKind::kMerge,
                *session)) {
          result->Error("cursor_adapter_unavailable",
                        "The native cursor adapter is unavailable.");
          return;
        }
        result->Success();
      });

  transcript_cursor_subclassed_ =
      SetWindowSubclass(flutter_view_window_, TranscriptCursorSubclassProc,
                        kTranscriptCursorSubclassId,
                        reinterpret_cast<DWORD_PTR>(this)) != FALSE;
}

bool FlutterWindow::ActivateTranscriptStructureCursor(
    TranscriptCursorKind kind, int64_t session) {
  EnsureTranscriptStructureCursors();
  active_transcript_cursor_session_ = session;
  active_transcript_cursor_ =
      kind == TranscriptCursorKind::kSplit ? split_cursor_ : merge_cursor_;
  if (active_transcript_cursor_) {
    SetCursor(active_transcript_cursor_);
    return true;
  }
  active_transcript_cursor_session_ = -1;
  return false;
}

void FlutterWindow::DeactivateTranscriptStructureCursor(int64_t session) {
  if (active_transcript_cursor_session_ != session) {
    return;
  }
  // A late clear must only release this generation. Do not install a fallback:
  // Flutter may already own a newer merge, I-beam, forbidden, or basic cursor.
  active_transcript_cursor_session_ = -1;
  active_transcript_cursor_ = nullptr;
}

void FlutterWindow::DeactivateAllTranscriptStructureCursors() {
  active_transcript_cursor_session_ = -1;
  active_transcript_cursor_ = nullptr;
}

void FlutterWindow::EnsureTranscriptStructureCursors() {
  const UINT dpi = flutter_view_window_ ? GetDpiForWindow(flutter_view_window_)
                                       : USER_DEFAULT_SCREEN_DPI;
  if (split_cursor_ && merge_cursor_ && transcript_cursor_dpi_ == dpi) {
    return;
  }
  DestroyTranscriptStructureCursors();
  transcript_cursor_dpi_ = dpi;
  split_cursor_ =
      CreateTranscriptStructureCursor(TranscriptCursorKind::kSplit, dpi);
  merge_cursor_ =
      CreateTranscriptStructureCursor(TranscriptCursorKind::kMerge, dpi);
}

void FlutterWindow::DestroyTranscriptStructureCursors() {
  if (split_cursor_) {
    DestroyCursor(split_cursor_);
    split_cursor_ = nullptr;
  }
  if (merge_cursor_) {
    DestroyCursor(merge_cursor_);
    merge_cursor_ = nullptr;
  }
  transcript_cursor_dpi_ = 0;
}

HCURSOR FlutterWindow::CreateTranscriptStructureCursor(
    TranscriptCursorKind kind, UINT dpi) const {
  const int width = std::max(24, GetSystemMetricsForDpi(SM_CXCURSOR, dpi));
  const int height = std::max(24, GetSystemMetricsForDpi(SM_CYCURSOR, dpi));
  const double scale_x = width / 24.0;
  const double scale_y = height / 24.0;
  const double stroke_scale = std::min(scale_x, scale_y);
  const std::vector<CursorLine> lines = kind == TranscriptCursorKind::kSplit
      ? std::vector<CursorLine>{{12, 3, 12, 21}, {9, 8, 5, 8},
                                {5, 8, 7, 6}, {15, 16, 19, 16},
                                {19, 16, 17, 18}}
      : std::vector<CursorLine>{{12, 3, 12, 10}, {8, 7, 12, 11},
                                {12, 11, 16, 7}, {12, 21, 12, 14},
                                {8, 17, 12, 13}, {12, 13, 16, 17}};

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;
  void* color_bits = nullptr;
  HDC screen_dc = GetDC(nullptr);
  HBITMAP color_bitmap =
      CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS, &color_bits,
                       nullptr, 0);
  ReleaseDC(nullptr, screen_dc);
  if (!color_bitmap || !color_bits) {
    if (color_bitmap) {
      DeleteObject(color_bitmap);
    }
    return nullptr;
  }

  const int mask_stride = ((width + 15) / 16) * 2;
  std::vector<unsigned char> mask_bits(mask_stride * height, 0xFF);
  auto* pixels = static_cast<std::uint32_t*>(color_bits);
  std::fill(pixels, pixels + width * height, 0u);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      double nearest = 1e9;
      for (const auto& logical : lines) {
        const CursorLine scaled{logical.x1 * scale_x, logical.y1 * scale_y,
                                logical.x2 * scale_x, logical.y2 * scale_y};
        nearest = std::min(nearest,
                           DistanceToLine(x + 0.5, y + 0.5, scaled));
      }
      if (nearest > 2.25 * stroke_scale) {
        continue;
      }
      const int byte_index = y * mask_stride + x / 8;
      mask_bits[byte_index] &=
          static_cast<unsigned char>(~(0x80u >> (x % 8)));
      pixels[y * width + x] = nearest <= 1.05 * stroke_scale
                                  ? 0xFF000000u
                                  : 0xFFFFFFFFu;
    }
  }

  HBITMAP mask_bitmap =
      CreateBitmap(width, height, 1, 1, mask_bits.data());
  if (!mask_bitmap) {
    DeleteObject(color_bitmap);
    return nullptr;
  }
  ICONINFO icon_info{};
  icon_info.fIcon = FALSE;
  icon_info.xHotspot = width / 2;
  icon_info.yHotspot = height / 2;
  icon_info.hbmMask = mask_bitmap;
  icon_info.hbmColor = color_bitmap;
  HCURSOR cursor = static_cast<HCURSOR>(CreateIconIndirect(&icon_info));
  DeleteObject(mask_bitmap);
  DeleteObject(color_bitmap);
  return cursor;
}

LRESULT CALLBACK FlutterWindow::TranscriptCursorSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) {
  auto* owner = reinterpret_cast<FlutterWindow*>(reference_data);
  if (message == WM_SETCURSOR && owner->active_transcript_cursor_ &&
      LOWORD(lparam) == HTCLIENT) {
    SetCursor(owner->active_transcript_cursor_);
    return TRUE;
  }
  if (message == WM_MOUSELEAVE || message == WM_KILLFOCUS) {
    owner->DeactivateAllTranscriptStructureCursors();
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, TranscriptCursorSubclassProc, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}
