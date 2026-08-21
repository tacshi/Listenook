#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  enum class TranscriptCursorKind { kSplit, kMerge };

  void RegisterTranscriptStructureCursor();
  bool ActivateTranscriptStructureCursor(TranscriptCursorKind kind,
                                         int64_t session);
  void DeactivateTranscriptStructureCursor(int64_t session);
  void DeactivateAllTranscriptStructureCursors();
  void EnsureTranscriptStructureCursors();
  void DestroyTranscriptStructureCursors();
  HCURSOR CreateTranscriptStructureCursor(TranscriptCursorKind kind,
                                          UINT dpi) const;
  static LRESULT CALLBACK TranscriptCursorSubclassProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam,
      UINT_PTR subclass_id, DWORD_PTR reference_data);

  // The project to run.
  flutter::DartProject project_;
  bool start_hidden_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      transcript_cursor_channel_;
  HWND flutter_view_window_ = nullptr;
  HCURSOR split_cursor_ = nullptr;
  HCURSOR merge_cursor_ = nullptr;
  HCURSOR active_transcript_cursor_ = nullptr;
  UINT transcript_cursor_dpi_ = 0;
  int64_t active_transcript_cursor_session_ = -1;
  bool transcript_cursor_subclassed_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
