import 'package:flutter/widgets.dart';

import 'app_window.dart';

/// One OS window and what renders into it.
class AppWindowEntry {
  AppWindowEntry({required this.window, required this.builder});

  final AppWindow window;
  final WidgetBuilder builder;
}

/// Every window the app has open. All of them are views of the one engine, so
/// state is shared by simply sitting above [AppWindowsHost] in the tree —
/// there is no cross-window messaging.
///
/// An entry must stay registered until its window is destroyed: removing it
/// unmounts the window's content, and a live window with no view content just
/// stops painting.
class AppWindowRegistry extends ChangeNotifier {
  final List<AppWindowEntry> _entries = [];

  List<AppWindowEntry> get entries => List.unmodifiable(_entries);

  void add(AppWindowEntry entry) {
    _entries.add(entry);
    notifyListeners();
  }

  void remove(AppWindowEntry entry) {
    if (_entries.remove(entry)) notifyListeners();
  }

  /// Rebuilds [entry]'s content, e.g. after the builder's inputs changed.
  void refresh() => notifyListeners();
}

/// Renders each registered window as its own view. This is the app's root on
/// desktop: `runWidget(AppWindowsHost(...))`, with any app-wide providers
/// wrapped around it.
class AppWindowsHost extends StatelessWidget {
  const AppWindowsHost({super.key, required this.registry});

  final AppWindowRegistry registry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) => ViewCollection(
        views: [
          for (final entry in registry.entries)
            AppWindowView(
              key: ObjectKey(entry),
              window: entry.window,
              child: Builder(builder: entry.builder),
            ),
        ],
      ),
    );
  }
}
