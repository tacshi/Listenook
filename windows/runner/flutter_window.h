#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>

#include "win32_window.h"
#include "window_handle_channel.h"

// The runner's own window. It hosts the engine and its implicit view but is
// never shown: every visible window — the main window and each video player —
// is created from Dart through Flutter's windowing API (lib/core/windowing/).
// It stays as the process's anchor: plugins that look for "the" window find
// it, and destroying it ends the message loop.
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
  enum class TranscriptCursorKind { kSplit, kMerge };

  void RegisterTranscriptStructureCursor();
  // Moves the split/merge cursor onto the Flutter view of Dart's main window.
  void AttachTranscriptCursor(HWND main_window);
  void DetachTranscriptCursor();
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

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      transcript_cursor_channel_;
  std::unique_ptr<WindowHandleChannel> window_handles_;
  HWND flutter_view_window_ = nullptr;
  HCURSOR split_cursor_ = nullptr;
  HCURSOR merge_cursor_ = nullptr;
  HCURSOR active_transcript_cursor_ = nullptr;
  UINT transcript_cursor_dpi_ = 0;
  int64_t active_transcript_cursor_session_ = -1;
  bool transcript_cursor_subclassed_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
