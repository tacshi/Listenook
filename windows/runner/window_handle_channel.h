#ifndef RUNNER_WINDOW_HANDLE_CHANNEL_H_
#define RUNNER_WINDOW_HANDLE_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>

// `app.capyvibe.listenook/window_handle`: native operations on the windows
// Dart creates through Flutter's windowing API, for what that API does not
// offer — hiding without destroying (close to tray), starting hidden,
// aspect-ratio locking, centering and the main window's custom title bar.
// Windows are addressed by their HWND as an integer; a handle that is no
// longer a live window of this process is ignored.
// Dart side: lib/core/windowing/window_handle_channel.dart.
class WindowHandleChannel {
 public:
  // |on_main_window| runs when Dart registers its main window, so the runner
  // can attach what used to live on its own window (the transcript cursor).
  WindowHandleChannel(flutter::FlutterEngine* engine,
                      std::function<void(HWND)> on_main_window);
  ~WindowHandleChannel();

  WindowHandleChannel(const WindowHandleChannel&) = delete;
  WindowHandleChannel& operator=(const WindowHandleChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::function<void(HWND)> on_main_window_;
};

#endif  // RUNNER_WINDOW_HANDLE_CHANNEL_H_
