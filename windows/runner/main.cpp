#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Dart decides whether the main window starts hidden (--background, or a
  // launch that only opens a video).
  project.set_dart_entrypoint_arguments(command_line_arguments);

  // The hidden host of the engine (see FlutterWindow). It never renders, so
  // its implicit view needs no real surface; the app's windows come from Dart.
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(64, 64);
  if (!window.Create(L"Listenook", origin, size)) {
    return EXIT_FAILURE;
  }
  // Destroying the host (only ever on the way out) ends the message loop.
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
